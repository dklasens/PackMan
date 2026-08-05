using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using PackMan.Services;
using PackMan.ViewModels;

namespace PackMan;

public partial class App : Application
{
    private static readonly IHost AppHost = Host.CreateDefaultBuilder()
        .ConfigureServices((_, services) =>
        {
            services.AddSingleton<IElevationBroker, ElevationBroker>();
            services.AddSingleton<IProcessRunner, ProcessRunner>();
            services.AddSingleton<IToolResolver, ToolResolver>();
            services.AddSingleton(new HttpClient { Timeout = TimeSpan.FromSeconds(20) });
            if (UiTestEnvironment.Scenario is { } scenario)
            {
                services.AddSingleton<ISettingsService, UiTestSettings>();
                services.AddSingleton<IPackageSource>(new UiTestPackageSource(scenario));
            }
            else
            {
                services.AddSingleton<ISettingsService, SettingsService>();
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
        }).Build();

    private bool _hostStarted;

    protected override async void OnStartup(StartupEventArgs e)
    {
        if (ElevationBroker.IsHelper(e.Args))
        {
            var exitCode = await ElevationBroker.RunHelperAsync(e.Args);
            Shutdown(exitCode);
            return;
        }
        await AppHost.StartAsync();
        _hostStarted = true;
        Wpf.Ui.Appearance.ApplicationThemeManager.ApplySystemTheme();
        var window = AppHost.Services.GetRequiredService<MainWindow>();
        MainWindow = window;
        window.Show();
        base.OnStartup(e);
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        if (_hostStarted)
        {
            await AppHost.StopAsync();
            AppHost.Dispose();
        }
        base.OnExit(e);
    }
}
