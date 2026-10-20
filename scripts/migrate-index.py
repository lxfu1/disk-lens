#!/usr/bin/env python3
"""Compact a CLOSED DiskLens v2/v3/v4 cache into schema v5, preserving saved work.

Creates and verifies a sibling database before atomic replacement. A .pre-v5
hard-link backup retains the checkpointed original; remove it via Cache Management
only after verifying the new application. No user files are scanned or modified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time

# Shared with the application; no divergent legacy schema implementation.
SCHEMA = (Path(__file__).resolve().parents[1] / 'Sources/IndexSchema.swift').read_text().split('"""')[1]


def require_closed():
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
    if any(line.strip().endswith('/Contents/MacOS/DiskLens') for line in processes.splitlines()):
        raise RuntimeError('Quit DiskLens before migrating its cache.')


def digest_row(digest, row):
    digest.update(json.dumps(list(row), ensure_ascii=True, separators=(',', ':')).encode())
    digest.update(b'\n')


def migrate(source: Path, report=print):
    source = source.resolve(strict=True)
    require_closed()
    stage = source.with_name(source.name + '.migrating')
    backup = source.with_name(source.name + '.pre-v5')
    started = time.monotonic()
    old = sqlite3.connect(source.as_uri() + '?mode=rw', uri=True, timeout=1)
    new = None
    try:
        version = old.execute('PRAGMA user_version').fetchone()[0]
        if version == 5:
            report('Already schema v5; no migration needed.')
            return
        if version not in (2, 3, 4):
            raise RuntimeError(f'Unsupported source schema: {version}')
        if backup.exists() or any(Path(str(stage) + suffix).exists() for suffix in ('', '-journal', '-wal', '-shm')):
            raise RuntimeError('Existing .migrating or .pre-v5 files must be reviewed before retrying; the source has not been replaced.')
        if old.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0] != 0:
            raise RuntimeError('Cache has active readers; close other connections.')
        old.execute('BEGIN IMMEDIATE')
        before = source.stat().st_size
        if shutil.disk_usage(source.parent).free < before + 64 * 1024**2:
            raise RuntimeError('Migration requires free working space of at least the source size plus 64 MiB.')
        new = sqlite3.connect(stage)
        new.execute('PRAGMA auto_vacuum=INCREMENTAL')
        new.execute('PRAGMA synchronous=FULL')
        deferred = [line for line in SCHEMA.splitlines() if line.startswith(('CREATE INDEX ', 'CREATE TRIGGER '))]
        new.executescript('\n'.join(line for line in SCHEMA.splitlines() if line not in deferred))
        estimates = {}
        revision = "revision" if version == 4 else "''"
        root_id = 'rowid' if version == 2 else 'id'
        roots = old.execute(f'SELECT {root_id},path,file_id,event_uuid,cursor,updated,incomplete,target_cursor,{revision} FROM roots ORDER BY {root_id}').fetchall()
        new.executemany('INSERT INTO roots(id,path,file_id,event_uuid,cursor,updated,incomplete,target_cursor,revision,last_used) VALUES(?,?,?,?,?,?,?,?,?,?)', [r + (r[5],) for r in roots])
        new.commit()
        seen = 'n.seen' if version == 4 else '0'
        if version == 2:
            query = '''SELECT n.rowid,r.rowid,n.path,COALESCE(p.rowid,0),n.kind,n.device,n.inode,n.nlink,n.raw,n.bytes,n.files,n.issue,n.skipped,0
                       FROM nodes n JOIN roots r ON r.path=n.scope
                       LEFT JOIN nodes p ON p.scope=n.scope AND p.path=n.parent ORDER BY n.rowid'''
        else:
            query = f'''SELECT n.id,n.scope,n.path,n.parent,n.kind,n.device,n.inode,n.nlink,n.raw,n.bytes,n.files,n.issue,n.skipped,{seen}
                        FROM nodes n JOIN roots r ON r.id=n.scope ORDER BY n.id'''
        expected_digest = hashlib.blake2b()
        folders = {}
        copied = 0
        cursor = old.execute(query)
        while batch := cursor.fetchmany(2048):
            converted = []
            for raw in batch:
                row = list(raw)
                row[5] = int(row[5])
                row[6] = str(row[6])  # Never narrow unsigned inode identifiers.
                digest_row(expected_digest, row)
                parent, name = row[2].rsplit('/', 1)
                parent = parent or '/'
                key = (row[1], parent)
                if key not in folders:
                    found = new.execute('SELECT id FROM folders WHERE scope=? AND path=?', key).fetchone()
                    if found is None:
                        folder_id = new.execute('INSERT INTO folders(scope,path) VALUES(?,?)', key).lastrowid
                        estimates[row[1]] = estimates.get(row[1], 0) + 64 + 2 * len(parent.encode())
                    else:
                        folder_id = found[0]
                    if len(folders) >= 8192:
                        folders.clear()
                    folders[key] = folder_id
                converted.append(row[:2] + [folders[key], name] + row[3:])
                estimates[row[1]] = estimates.get(row[1], 0) + 160 + 2 * len(name.encode())
            new.executemany('INSERT INTO nodes(id,scope,folder,name,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped,seen) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', converted)
            new.commit()
            copied += len(batch)
            if copied % 16384 == 0:
                report(f'Copied {copied:,} nodes ({time.monotonic()-started:.1f}s)')
        for table, columns in [('jobs', 't.path,t.mode'), ('dirty_dirs', 't.path,t.depth'), ('dirty_links', 'CAST(t.device AS INTEGER),CAST(t.inode AS TEXT),CAST(t.size AS INTEGER)')]:
            join = 'r.path=t.scope' if version == 2 else 'r.id=t.scope'
            rid = 'r.rowid' if version == 2 else 'r.id'
            order = f'{rid},CAST(t.device AS INTEGER),t.inode' if table == 'dirty_links' else f'{rid},t.path'
            cursor = old.execute(f'SELECT {rid},{columns} FROM {table} t JOIN roots r ON {join} ORDER BY {order}')
            task_digest = hashlib.blake2b()
            count = 0
            while batch := cursor.fetchmany(2048):
                new.executemany(f'INSERT INTO {table} VALUES({",".join("?" for _ in batch[0])})', batch)
                for row in batch:
                    digest_row(task_digest, row)
                count += len(batch)
            new.commit()
            if new.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0] != count:
                raise RuntimeError(f'{table}: count mismatch')
            result_digest = hashlib.blake2b()
            order = 'scope,device,inode' if table == 'dirty_links' else 'scope,path'
            for row in new.execute(f'SELECT * FROM {table} ORDER BY {order}'):
                digest_row(result_digest, row)
            if result_digest.digest() != task_digest.digest():
                raise RuntimeError(f'{table}: saved work differs from source')
        report('Building compact indexes…')
        new.executescript('\n'.join(deferred))
        new.executemany('UPDATE roots SET estimated_bytes=? WHERE id=?', [(value, key) for key, value in estimates.items()])
        # Preserve high-water IDs, including IDs of previously removed nodes.
        if old.execute("SELECT 1 FROM sqlite_master WHERE name='sqlite_sequence'").fetchone():
            for name, seq in old.execute('SELECT name,seq FROM sqlite_sequence'):
                if name in ('nodes', 'roots'):
                    new.execute('UPDATE sqlite_sequence SET seq=MAX(seq,?) WHERE name=?', (seq, name))
        new.commit()
        report('Verifying reconstructed paths, identities, summaries, enumeration markers and saved work…')
        actual_digest = hashlib.blake2b()
        actual_count = 0
        for row in new.execute('SELECT id,scope,path,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped,seen FROM node_paths ORDER BY id'):
            digest_row(actual_digest, row)
            actual_count += 1
        if actual_count != copied or actual_digest.digest() != expected_digest.digest():
            raise RuntimeError('Reconstructed metadata differs from source; original retained.')
        if new.execute('SELECT id,path,file_id,event_uuid,cursor,updated,incomplete,target_cursor,revision FROM roots ORDER BY id').fetchall() != roots:
            raise RuntimeError('Root state or event cursors changed during migration.')
        if new.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
            raise RuntimeError('New cache failed SQLite quick_check.')
        if new.execute('PRAGMA auto_vacuum').fetchone()[0] != 2:
            raise RuntimeError('Incremental space reclamation was not enabled.')
        # Finalize all verification statements before switching journal modes.
        new.close()
        new = sqlite3.connect(stage)
        new.execute('PRAGMA journal_mode=WAL').fetchall()
        if new.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall()[0][0] != 0:
            raise RuntimeError('Could not finalize new cache WAL.')
        new.close()
        new = None
        os.chmod(stage, source.stat().st_mode & 0o777)
        with stage.open('rb') as file:
            os.fsync(file.fileno())
        require_closed()
        old.rollback()
        old.close()
        old = None
        os.link(source, backup)  # No extra copy; preserve original through the atomic swap.
        for suffix in ('-wal', '-shm'):
            Path(str(source) + suffix).unlink(missing_ok=True)
        os.replace(stage, source)
        fd = os.open(source.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        after = source.stat().st_size
        report(f'Migrated {copied:,} nodes: {before:,} -> {after:,} bytes ({100*(1-after/before):.1f}% smaller), {time.monotonic()-started:.1f}s. Backup retained at {backup}; total disk use will fall only after removing that backup.')
    finally:
        if new is not None:
            new.close()
        if old is not None:
            old.rollback()
            old.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('database', type=Path, nargs='?', default=Path.home() / 'Library/Application Support/DiskLens/index.sqlite')
    args = parser.parse_args()
    migrate(args.database)
