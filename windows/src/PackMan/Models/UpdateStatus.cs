namespace PackMan.Models;

public enum UpdateStatus
{
    Pending,
    Updating,
    Verifying,
    Failed,
    Cancelled,
    Updated,
    Verified,
}

public enum UpdateFailureKind
{
    Update,
    Verification,
}
