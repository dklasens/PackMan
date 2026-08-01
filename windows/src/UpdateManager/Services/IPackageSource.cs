using UpdateManager.Models;

namespace UpdateManager.Services;

public interface IPackageSource
{
    string Name { get; }

    Task<bool> IsAvailableAsync();

    Task<IReadOnlyList<PackageUpdate>> ScanAsync(CancellationToken cancellationToken = default);

    Task UpdateAsync(PackageUpdate package, IProgress<string>? progress = null, CancellationToken cancellationToken = default);
}
