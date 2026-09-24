; Native SQLite ownership only. No application schema or UI dependencies.
class SqliteConnection {
    static Library := A_WinDir "\System32\winsqlite3.dll"
    static Module := 0
    __New(path, create := false) {
        this.Handle := 0, this.Statements := Map()
        if !SqliteConnection.Module {
            SqliteConnection.Module := DllCall("LoadLibraryExW", "Str", SqliteConnection.Library, "Ptr", 0, "UInt", 0x800, "Ptr")
            if !SqliteConnection.Module
                throw Error("Windows標準SQLiteを読み込めません。対応するWindows環境を確認してください。")
        }
        utf8 := Buffer(StrPut(path,"UTF-8")), StrPut(path,utf8,"UTF-8")
        rc := DllCall(SqliteConnection.Library "\sqlite3_open_v2", "Ptr", utf8, "Ptr*", &handle:=0, "Int", create ? 6 : 2, "Ptr", 0, "CDecl Int")
        this.Handle := handle
        try {
            this.Check(rc)
            this.Exec("PRAGMA busy_timeout=100")
        } catch as failure {
            this.Close()
            throw failure
        }
    }
    ConfigureStorage() {
        if this.Scalar("PRAGMA journal_mode=DELETE") != "delete"
            throw Error("SQLiteのDELETEモードを設定できません。")
        this.Exec("PRAGMA synchronous=EXTRA; PRAGMA foreign_keys=ON")
        if this.Scalar("PRAGMA synchronous") != "3" || this.Scalar("PRAGMA foreign_keys") != "1"
            throw Error("SQLiteの保存保護設定を有効にできません。")
    }
    Check(code) {
        if code {
            detail := this.Handle ? StrGet(DllCall(SqliteConnection.Library "\sqlite3_errmsg16", "Ptr", this.Handle, "CDecl Ptr"),"UTF-16") : "接続できません"
            throw Error("設定データベースの処理に失敗しました (SQLite " code "): " detail)
        }
    }
    Exec(sql) {
        this.Check(DllCall(SqliteConnection.Library "\sqlite3_exec", "Ptr", this.Handle, "AStr", sql, "Ptr", 0, "Ptr", 0, "Ptr", 0, "CDecl Int"))
    }
    Statement(sql, values) {
        if !this.Statements.Has(sql) {
            this.Check(DllCall(SqliteConnection.Library "\sqlite3_prepare16_v2", "Ptr", this.Handle, "WStr", sql, "Int", -1, "Ptr*", &stmt:=0, "Ptr", 0, "CDecl Int"))
            this.Statements[sql] := stmt
        }
        ; Run/Rows and binding failures return cached statements reset and unbound.
        stmt := this.Statements[sql]
        try {
            for index, value in values {
                if Type(value) = "Integer"
                    rc := DllCall(SqliteConnection.Library "\sqlite3_bind_int64", "Ptr", stmt, "Int", index, "Int64", value, "CDecl Int")
                else
                    rc := DllCall(SqliteConnection.Library "\sqlite3_bind_text16", "Ptr", stmt, "Int", index, "WStr", value, "Int", StrLen(value)*2, "Ptr", -1, "CDecl Int")
                this.Check(rc)
            }
        } catch as failure {
            this.Reset(stmt)
            throw failure
        }
        return stmt
    }
    Reset(stmt) {
        ; reset reports the preceding step error again; callers already checked it.
        DllCall(SqliteConnection.Library "\sqlite3_reset", "Ptr", stmt, "CDecl Int")
        DllCall(SqliteConnection.Library "\sqlite3_clear_bindings", "Ptr", stmt, "CDecl Int")
    }
    Run(sql, values*) {
        stmt := this.Statement(sql,values)
        try {
            rc := DllCall(SqliteConnection.Library "\sqlite3_step", "Ptr", stmt, "CDecl Int")
            if rc != 101
                this.Check(rc)
        } finally this.Reset(stmt)
    }
    Rows(sql, values*) {
        stmt := this.Statement(sql,values), rows := []
        try {
            columns := DllCall(SqliteConnection.Library "\sqlite3_column_count", "Ptr", stmt, "CDecl Int")
            loop {
                rc := DllCall(SqliteConnection.Library "\sqlite3_step", "Ptr", stmt, "CDecl Int")
                if rc = 101
                    break
                if rc != 100
                    this.Check(rc)
                row := []
                Loop columns {
                    ptr := DllCall(SqliteConnection.Library "\sqlite3_column_text16", "Ptr", stmt, "Int", A_Index-1, "CDecl Ptr")
                    row.Push(ptr ? StrGet(ptr,"UTF-16") : "")
                }
                rows.Push(row)
            }
        } finally this.Reset(stmt)
        return rows
    }
    Scalar(sql, values*) {
        rows := this.Rows(sql,values*)
        return rows.Length ? rows[1][1] : ""
    }
    Transaction(action, writable := true) {
        this.Exec(writable ? "BEGIN IMMEDIATE" : "BEGIN")
        try {
            result := action.Call()
            this.Exec("COMMIT")
            return result
        } catch as failure {
            if !DllCall(SqliteConnection.Library "\sqlite3_get_autocommit", "Ptr", this.Handle, "CDecl Int") {
                try this.Exec("ROLLBACK")
                catch {
                    this.Close()
                }
            }
            throw failure
        }
    }
    Backup(path) {
        if FileExist(path)
            throw Error("バックアップ先は既に存在します。")
        target := SqliteConnection(path,true), backup := 0
        try {
            target.ConfigureStorage()
            backup := DllCall(SqliteConnection.Library "\sqlite3_backup_init", "Ptr", target.Handle, "AStr", "main", "Ptr", this.Handle, "AStr", "main", "CDecl Ptr")
            if !backup
                throw Error("バックアップを開始できません。")
            rc := DllCall(SqliteConnection.Library "\sqlite3_backup_step", "Ptr", backup, "Int", -1, "CDecl Int")
            finish := DllCall(SqliteConnection.Library "\sqlite3_backup_finish", "Ptr", backup, "CDecl Int"), backup := 0
            if rc != 101
                target.Check(rc)
            target.Check(finish)
            if target.Scalar("PRAGMA integrity_check") != "ok"
                throw Error("バックアップの整合性を確認できません。")
        } finally {
            if backup
                DllCall(SqliteConnection.Library "\sqlite3_backup_finish", "Ptr", backup, "CDecl Int")
            target.Close()
        }
    }
    Close() {
        if !this.Handle
            return
        for sql, stmt in this.Statements
            DllCall(SqliteConnection.Library "\sqlite3_finalize", "Ptr", stmt, "CDecl Int")
        this.Statements.Clear()
        rc := DllCall(SqliteConnection.Library "\sqlite3_close", "Ptr", this.Handle, "CDecl Int")
        this.Check(rc)
        this.Handle := 0
    }
    __Delete() {
        try this.Close()
    }
}
