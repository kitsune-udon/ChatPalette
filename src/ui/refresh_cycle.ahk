; Coalesce reentrant refreshes without sharing a screen's controls or presentation data.
class RefreshCycle {
    __New(callback) {
        this.Active := false, this.Pending := false, this.Callback := callback
    }
    Begin() {
        if this.Active {
            this.Pending := true
            return false
        }
        this.Active := true
        return true
    }
    End() {
        this.Active := false
        if this.Pending {
            this.Pending := false
            SetTimer(this.Callback,-1)
        }
    }
}
