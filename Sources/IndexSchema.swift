// The offline migration reads this SQL as well; keep the schema in one place.
enum IndexSchema {
    static let sql = """
CREATE TABLE roots(id INTEGER PRIMARY KEY AUTOINCREMENT,path TEXT NOT NULL UNIQUE,file_id TEXT NOT NULL,event_uuid TEXT NOT NULL,cursor TEXT NOT NULL,updated REAL NOT NULL,incomplete INTEGER NOT NULL,target_cursor TEXT NOT NULL,revision TEXT NOT NULL DEFAULT '',last_used REAL NOT NULL DEFAULT 0,estimated_bytes INTEGER NOT NULL DEFAULT 0);
CREATE TABLE folders(id INTEGER PRIMARY KEY,scope INTEGER NOT NULL,path TEXT NOT NULL,UNIQUE(scope,path));
CREATE TABLE nodes(id INTEGER PRIMARY KEY AUTOINCREMENT,scope INTEGER NOT NULL,folder INTEGER NOT NULL,name TEXT NOT NULL,parent INTEGER NOT NULL,kind INTEGER NOT NULL,device INTEGER NOT NULL,inode TEXT NOT NULL,nlink INTEGER NOT NULL,raw INTEGER NOT NULL,bytes INTEGER NOT NULL,files INTEGER NOT NULL,issue INTEGER NOT NULL,skipped INTEGER NOT NULL,seen INTEGER NOT NULL DEFAULT 0,UNIQUE(scope,folder,name));
CREATE VIEW node_paths AS SELECT n.*,CASE WHEN f.path='/' THEN '/'||n.name ELSE f.path||'/'||n.name END AS path FROM nodes n JOIN folders f ON f.id=n.folder;
CREATE INDEX nodes_parent ON nodes(scope,parent,bytes DESC,id);
CREATE INDEX nodes_identity ON nodes(scope,inode) WHERE kind=1;
CREATE INDEX nodes_largest ON nodes(scope,bytes DESC,id) WHERE kind=1;
CREATE INDEX nodes_issues ON nodes(scope,id) WHERE issue>0;
CREATE INDEX nodes_seen ON nodes(scope,parent,seen);
CREATE TABLE jobs(scope INTEGER NOT NULL,path TEXT NOT NULL,mode INTEGER NOT NULL,PRIMARY KEY(scope,path));
CREATE TABLE dirty_dirs(scope INTEGER NOT NULL,path TEXT NOT NULL,depth INTEGER NOT NULL,PRIMARY KEY(scope,path));
CREATE INDEX dirty_depth ON dirty_dirs(scope,depth DESC,path);
CREATE TABLE dirty_links(scope INTEGER NOT NULL,device INTEGER NOT NULL,inode TEXT NOT NULL,size INTEGER,PRIMARY KEY(scope,device,inode));
CREATE TABLE garbage(scope INTEGER PRIMARY KEY);
CREATE TRIGGER nodes_storage_insert AFTER INSERT ON nodes BEGIN UPDATE roots SET estimated_bytes=estimated_bytes+160+2*length(CAST(NEW.name AS BLOB)) WHERE id=NEW.scope; END;
CREATE TRIGGER nodes_storage_delete AFTER DELETE ON nodes BEGIN UPDATE roots SET estimated_bytes=MAX(0,estimated_bytes-160-2*length(CAST(OLD.name AS BLOB))) WHERE id=OLD.scope; END;
CREATE TRIGGER folders_storage_insert AFTER INSERT ON folders BEGIN UPDATE roots SET estimated_bytes=estimated_bytes+64+2*length(CAST(NEW.path AS BLOB)) WHERE id=NEW.scope; END;
CREATE TRIGGER folders_storage_delete AFTER DELETE ON folders BEGIN UPDATE roots SET estimated_bytes=MAX(0,estimated_bytes-64-2*length(CAST(OLD.path AS BLOB))) WHERE id=OLD.scope; END;
PRAGMA user_version=5;
"""
}
