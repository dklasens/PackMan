using System.Diagnostics;
using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using PackMan.Services;
using PackMan.ViewModels;

namespace PackMan;

public partial class App : Application
{
    private static readonly bool LaunchDiagnostics =
        string.Equals(Environment.GetEnvironmentVariable("PACKMAN_DIAGNOSTICS"), "1", StringComparison.Ordinal);

    private ServiceProvider? _services;

    protected override async void OnStartup(StartupEventArgs e)
    {
        var launchStart = Stopwatch.GetTimestamp();
        if (ElevationBroker.IsHelper(e.Args))
        {
            AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
            {
                if (eventArgs.ExceptionObject is Exception exception)
                    ElevationBroker.LogHelperFailure(exception);
            };
            var exitCode = await ElevationBroker.RunHelperAsync(e.Args);
            Shutdown(exitCode);
            return;
        }
        if (UpdateApplier.IsApplyMode(e.Args))
        {
            Shutdown(await UpdateApplier.RunAsync(e.Args));
            return;
        }
        UpdateApplier.CleanUpBackup();

        var services = new ServiceCollection();
        services.AddSingleton<IElevationBroker, ElevationBroker>();
        services.AddSingleton<IProcessRunner, ProcessRunner>();
        services.AddSingleton<IToolResolver, ToolResolver>();
        services.AddSingleton<ISourceInstaller, SourceInstaller>();
        services.AddSingleton(_ => new HttpClient { Timeout = TimeSpan.FromSeconds(20) });
        if (UiTestEnvironment.Scenario is { } scenario)
        {
            services.AddSingleton<ISettingsService, UiTestSettings>();
            services.AddSingleton<IPackageSource>(new UiTestPackageSource(scenario));
        }
        else
        {
            services.AddSingleton<ISettingsService, SettingsService>();
            services.AddSingleton<IAppUpdateService, AppUpdateService>();
            services.AddSingleton<IPackageSource, WingetSource>();
            services.AddSingleton<IPackageSource, ChocoSource>();
            services.AddSingleton<IPackageSource, ScoopSource>();
            services.AddSingleton<IPackageSource, NpmSource>();
            services.AddSingleton<IPackageSource, PipSource>();
            services.AddSingleton<IPackageSource, PipxSource>();
            services.AddSingleton<IPackageSource, DotnetSource>();
        }
        services.AddSingleton<MainViewModel>();
        services.AddSingleton<MainWindow>();
        _services = services.BuildServiceProvider();
        var servicesMs = ElapsedMilliseconds(launchStart);

        Wpf.Ui.Appearance.ApplicationThemeManager.ApplySystemTheme();
        var window = _services.GetRequiredService<MainWindow>();
        MainWindow = window;
        window.Show();
        base.OnStartup(e);

        if (window.DataContext is MainViewModel viewModel)
        {
            viewModel.BeginStartupUpdateCheck();
            if (LaunchDiagnostics)
                viewModel.LogLaunchDiagnostic(
                    $"Launch: services {servicesMs} ms, window shown {ElapsedMilliseconds(launchStart)} ms.");
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _services?.Dispose();
        base.OnExit(e);
    }

    private static long ElapsedMilliseconds(long start) =>
        (long)((Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency);
}
