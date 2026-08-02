namespace PackMan.Models;

public enum UpdateStatus
{
    Pending,
    Updating,
    Verifying,
    Failed,
    Cancelled,
}

public enum UpdateFailureKind
{
    Update,
    Verification,
}
