"""Small offline v2/v3/v4 migration fixtures; never open the real application cache."""
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import subprocess
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('migration', Path(__file__).resolve().parents[1] / 'scripts/migrate-index.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)

with tempfile.TemporaryDirectory(prefix='DiskLens-migration-') as directory, patch.object(migration, 'require_closed'):
    for version in (2, 3, 4):
        path = Path(directory) / f'v{version}.sqlite'
        db = sqlite3.connect(path)
        legacy = version == 2
        scope_type = 'TEXT' if legacy else 'INTEGER'
        root = '/Users/example/' + 'long-directory-' * 3 + '/项目'
        rid = root if legacy else 1
        parent = root if legacy else 1
        db.executescript(f'''
            CREATE TABLE roots({'' if legacy else 'id INTEGER PRIMARY KEY AUTOINCREMENT,'}path TEXT UNIQUE,file_id TEXT,event_uuid TEXT,cursor TEXT,updated REAL,incomplete INTEGER,target_cursor TEXT{",revision TEXT DEFAULT ''" if version == 4 else ''});
            CREATE TABLE nodes({'id INTEGER PRIMARY KEY AUTOINCREMENT,' if not legacy else ''}scope {scope_type},path TEXT,parent {scope_type},kind INTEGER,device INTEGER,inode TEXT,nlink INTEGER,raw INTEGER,bytes INTEGER,files INTEGER,issue INTEGER,skipped INTEGER{',seen INTEGER DEFAULT 0' if version == 4 else ''},UNIQUE(scope,path));
            CREATE INDEX nodes_parent ON nodes(scope,parent,bytes DESC{',id' if not legacy else ',path'},kind);
            CREATE INDEX nodes_identity ON nodes(scope,device,inode) WHERE kind=1;
            CREATE INDEX nodes_largest ON nodes(scope,bytes DESC{',id' if not legacy else ',path'}) WHERE kind=1;
            CREATE INDEX nodes_issues ON nodes(scope{',id' if not legacy else ',path'}) WHERE issue>0;
            CREATE TABLE jobs(scope {scope_type},path TEXT,mode INTEGER,PRIMARY KEY(scope,path));
            CREATE TABLE dirty_dirs(scope {scope_type},path TEXT,depth INTEGER,PRIMARY KEY(scope,path));
            CREATE INDEX dirty_depth ON dirty_dirs(scope,depth DESC,path);
            CREATE TABLE dirty_links(scope {scope_type},device INTEGER,inode TEXT,size INTEGER,PRIMARY KEY(scope,device,inode));
            CREATE TABLE garbage(scope {scope_type} PRIMARY KEY);
            PRAGMA user_version={version};
        ''')
        if version == 4:
            db.execute('CREATE INDEX nodes_seen ON nodes(scope,parent,seen)')
        db.execute('INSERT INTO roots(path,file_id,event_uuid,cursor,updated,incomplete,target_cursor) VALUES(?,?,?,?,?,?,?)', (root, '1:2', 'event-uuid', '9223372036854775809', 1234.5, 1, '9223372036854775810'))
        rows = [(rid, root, '' if legacy else 0, 0, 1, '2', 1, 0, 4096, 1, 0, 0)]
        rows += [(rid, root + '/文件-' + str(i), parent, 1, 1, '18446744073709551614' if i == 0 else str(i+10), 2 if i < 2 else 1, 4096, 4096, 1, 0, 0) for i in range(4000)]
        # An orphan from interrupted subtree deletion still needs its full path and pending job.
        rows += [(rid, root + '/missing-parent/orphan', '' if legacy else 0, 1, 1, '99', 1, 4096, 4096, 1, 0, 0)]
        db.executemany('INSERT INTO nodes(scope,path,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)', rows)
        if version == 4:
            db.execute('UPDATE nodes SET seen=17 WHERE kind=1')
            db.execute("UPDATE roots SET revision='retained-revision'")
        db.execute('INSERT INTO jobs VALUES(?,?,?)', (rid, root + '/missing-parent', 1))
        db.execute('INSERT INTO dirty_dirs VALUES(?,?,?)', (rid, root, len(root.encode())))
        db.execute('INSERT INTO dirty_links VALUES(?,?,?,?)', (rid, 1, '18446744073709551614', None))
        db.execute('INSERT INTO garbage VALUES(?)', (('/retired' if legacy else 999),))
        db.execute('INSERT INTO nodes(scope,path,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                   ('/retired' if legacy else 999, '/retired/file', '' if legacy else 0, 1, 1, '888', 1, 4096, 4096, 1, 0, 0))
        db.commit()
        db.close()
        original = path.read_bytes()
        before = len(original)
        if version == 4:
            with patch.object(migration.os, 'replace', side_effect=OSError('simulated swap failure')):
                try:
                    migration.migrate(path, report=lambda _: None)
                    raise AssertionError('expected failure')
                except OSError:
                    pass
            assert path.read_bytes() == original
            for suffix in ('.migrating', '.migrating-wal', '.migrating-shm', '.pre-v5'):
                Path(str(path) + suffix).unlink(missing_ok=True)
        migration.migrate(path)
        with sqlite3.connect(path) as new:
            assert new.execute('PRAGMA user_version').fetchone() == (5,)
            assert new.execute('PRAGMA auto_vacuum').fetchone() == (2,)
            assert new.execute('PRAGMA journal_mode').fetchone() == ('wal',)
            assert new.execute('SELECT COUNT(*) FROM nodes').fetchone() == (4002,)
            assert new.execute('SELECT cursor,target_cursor,incomplete FROM roots').fetchone() == ('9223372036854775809', '9223372036854775810', 1)
            assert new.execute('SELECT path,parent FROM node_paths WHERE name="orphan"').fetchone() == (root + '/missing-parent/orphan', 0)
            assert new.execute('SELECT inode,size FROM dirty_links').fetchone() == ('18446744073709551614', None)
            assert new.execute('SELECT inode FROM node_paths WHERE name="文件-0"').fetchone() == ('18446744073709551614',)
            assert new.execute('SELECT COUNT(*) FROM node_paths WHERE path LIKE ?', (root+'/%',)).fetchone() == (4001,)
            assert new.execute('SELECT COUNT(*) FROM garbage').fetchone() == (0,)
            assert new.execute('SELECT estimated_bytes FROM roots').fetchone()[0] > 0
            assert new.execute('SELECT MAX(seen) FROM nodes').fetchone() == (17 if version == 4 else 0,)
            assert new.execute('SELECT COUNT(*) FROM folders').fetchone()[0] == 3
        if '--reader' in sys.argv:
            reader = str(Path(sys.argv[sys.argv.index('--reader')+1]).resolve())
            subprocess.run([reader, '--inspect', str(path), root], check=True)
        assert Path(str(path)+'.pre-v5').read_bytes() == original
        assert path.stat().st_size < before * 0.65
        migration.migrate(path, report=lambda _: None)  # Idempotent even with retained backup.
        print(f'PASS v{version}: identity/paths/orphans/markers/tasks/cursors preserved; {100*(1-path.stat().st_size/before):.1f}% smaller; backup intact')
