import
  os, parsecfg, strutils, logging, contra,
  ../administration/create_standarddata,
  ../utils/logging_nimwc

from osproc import execCmdEx
from nativesockets import Port
from times import now, `$`

when defined(postgres): import db_postgres
else:                   import db_sqlite

let nimwcpkgDir = getAppDir().replace("/nimwcpkg", "")
const configFile = "config/config.cfg"
assert existsDir(nimwcpkgDir), "nimwcpkg directory not found: " & nimwcpkgDir
assert existsFile(configFile), "config/config.cfg file not found: " & configFile
setCurrentDir(nimwcpkgDir)

const
  sql_now =
    when defined(postgres): "(extract(epoch from now()))" # Postgres epoch.
    else:                   "(strftime('%s', 'now'))"     # SQLite 3 epoch.

  sql_timestamp =
    when defined(postgres): "integer"   # is internally Hardcoded to UTC anyways
    else:                   "timestamp" # SQLite 3 Timestamp.

  sql_id = # http://blog.2ndquadrant.com/postgresql-10-identity-columns
    when defined(postgres): "integer generated by default as identity"
    else:                   "integer"     # SQLite 3 integer ID.

  personTable = sql("""
    create table if not exists person(
      id         $3            primary key,
      name       varchar(60)   not null,
      password   varchar(300)  not null,
      twofa      varchar(60),
      email      varchar(254)  not null           unique,
      creation   $2            not null           default $1,
      modified   $2            not null           default $1,
      salt       varchar(128)  not null,
      status     varchar(30)   not null,
      timezone   varchar(100),
      secretUrl  varchar(250),
      lastOnline $2            not null           default $1,
      avatar     varchar(300)
    );""".format(sql_now, sql_timestamp, sql_id))

  sessionTable = sql("""
    create table if not exists session(
      id           $3                primary key,
      ip           inet              not null,
      key          varchar(300)      not null,
      userid       integer           not null,
      lastModified $2                not null     default $1,
      foreign key (userid) references person(id)
    );""".format(sql_now, sql_timestamp, sql_id))

  historyTable = sql("""
    create table if not exists history(
      id              $3             primary key,
      user_id         integer        not null,
      item_id         integer,
      element         varchar(100),
      choice          varchar(100),
      text            varchar(1000),
      creation        $2             not null     default $1
    );""".format(sql_now, sql_timestamp, sql_id))

  settingsTable = sql("""
    create table if not exists settings(
      id              $1             primary key,
      analytics       text,
      head            text,
      footer          text,
      navbar          text,
      title           text,
      disabled        integer,
      blogorder       text,
      blogsort        text
    );""".format(sql_id))

  pagesTable = sql("""
    create table if not exists pages(
      id              $3             primary key,
      author_id       INTEGER        NOT NULL,
      status          INTEGER        NOT NULL,
      name            VARCHAR(200)   NOT NULL,
      url             VARCHAR(200)   NOT NULL     UNIQUE,
      title           TEXT,
      metadescription TEXT,
      metakeywords    TEXT,
      description     TEXT,
      head            TEXT,
      navbar          TEXT,
      footer          TEXT,
      standardhead    INTEGER,
      standardnavbar  INTEGER,
      standardfooter  INTEGER,
      tags            VARCHAR(1000),
      category        VARCHAR(1000),
      date_start      VARCHAR(100),
      date_end        VARCHAR(100),
      views           INTEGER,
      public          INTEGER,
      changes         INTEGER,
      modified        $2             not null     default $1,
      creation        $2             not null     default $1,
      foreign key (author_id) references person(id)
    );""".format(sql_now, sql_timestamp, sql_id))

  blogTable = sql("""
    create table if not exists blog(
      id              $3             primary key,
      author_id       INTEGER        NOT NULL,
      status          INTEGER        NOT NULL,
      name            VARCHAR(200)   NOT NULL,
      url             VARCHAR(200)   NOT NULL     UNIQUE,
      title           TEXT,
      metadescription TEXT,
      metakeywords    TEXT,
      description     TEXT,
      head            TEXT,
      navbar          TEXT,
      footer          TEXT,
      standardhead    INTEGER,
      standardnavbar  INTEGER,
      standardfooter  INTEGER,
      tags            VARCHAR(1000),
      category        VARCHAR(1000),
      date_start      VARCHAR(100),
      date_end        VARCHAR(100),
      views           INTEGER,
      public          INTEGER,
      changes         INTEGER,
      pubDate         VARCHAR(100),
      modified        $2             not null     default $1,
      creation        $2             not null     default $1,
      viewCount       INTEGER        NOT NULL     default 1,
      foreign key (author_id) references person(id)
    );""".format(sql_now, sql_timestamp, sql_id))

  filesTable = sql("""
    create table if not exists files(
      id            $3                primary key,
      url           VARCHAR(1000)     NOT NULL     UNIQUE,
      downloadCount integer           NOT NULL     default 1,
      lastModified  $2                NOT NULL     default $1
    );""".format(sql_now, sql_timestamp, sql_id))

  sqlVacuum =
    when defined(postgres): sql"VACUUM (VERBOSE, ANALYZE);"
    else:                   sql"VACUUM;"

  fileBackup = "nimwc_" & (when defined(postgres): "postgres_" else: "sqlite_")

  cmdBackup =
    when defined(postgres): "pg_dump --verbose --no-password --encoding=UTF8 --lock-wait-timeout=99 --host=$1 --port=$2 --username=$3 --file='$4' --dbname=$5 $6"
    else: "sqlite3 -readonly -echo $1 '.backup $2'"

  cmdSign = "gpg --armor --detach-sign --yes --digest-algo sha512 "

  cmdChecksum = "sha512sum --tag "

  cmdTar = "tar cafv "


proc generateDB*(db: DbConn) =
  info("Database: Generating database")

  # User
  if not db.tryExec(personTable):
    info("Database: Person table already exists")

  # Session
  if not db.tryExec(sessionTable):
    info("Database: Session table already exists")

  # History
  if not db.tryExec(historyTable):
    info("Database: History table already exists")

  # Settings
  if not db.tryExec(settingsTable):
    info("Database: Settings table already exists")

  # Pages
  if not db.tryExec(pagesTable):
    info("Database: Pages table already exists")

  # Blog
  if not db.tryExec(blogTable):
    info("Database: Blog table already exists")

  # Files
  if not db.tryExec(filesTable):
    info("Database: Files table already exists")

  info("Database: Inserting standard elements")
  createStandardData(db)

  info("Database: Closing database")
  close(db)


proc backupDb*(dbname: string,
    filename = fileBackup & replace($now(), ":", "_") & ".sql",
    host = "localhost", port = Port(5432), username = getEnv("USER", "root"),
    dataOnly = false, inserts = false, checksum = true, sign = true, targz = true,
    ): tuple[output: TaintedString, exitCode: int] =
  ## Backup the whole Database to a plain-text Raw SQL Query human-readable file.
  preconditions(dbname.len > 1, host.len > 0, username.len > 0,
    when defined(postgres): findExe"pg_dump".len > 0 else: findExe"sqlite3".len > 0)
  when defined(postgres):
    var cmd = cmdBackup.format(host, port, username, filename, dbname,
    (if dataOnly: " --data-only " else: "") & (if inserts: " --inserts " else: ""))
  else:  # SQLite .dump is Not working, Docs says it should.
    var cmd = cmdBackup.format(dbname, filename)
  when not defined(release): echo cmd
  result = execCmdEx(cmd)
  if checksum and result.exitCode == 0 and findExe"sha512sum".len > 0:
    cmd = cmdChecksum & filename & " > " & filename & ".sha512"
    when not defined(release): echo cmd
    result = execCmdEx(cmd)
    if sign and result.exitCode == 0 and findExe"gpg".len > 0:
      cmd = cmdSign & filename
      when not defined(release): echo cmd
      result = execCmdEx(cmd)
      if targz and result.exitCode == 0 and findExe"tar".len > 0:
        cmd = cmdTar & filename & ".tar.gz " & filename & " " & filename & ".sha512 " & filename & ".asc"
        when not defined(release): echo cmd
        result = execCmdEx(cmd)
        if result.exitCode == 0:
          removeFile(filename)
          removeFile(filename & ".sha512")
          removeFile(filename & ".asc")


proc vacuumDb*(db: DbConn): bool {.inline.} =
  echo "Vacuum database (database maintenance)"
  db.tryExec(sqlVacuum)
