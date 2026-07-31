using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using UpdateManager.Services;
using UpdateManager.ViewModels;

namespace UpdateManager;

public partial class App : Application
{
    private static readonly IHost AppHost = Host.CreateDefaultBuilder()
        .ConfigureServices((_, services) =>
        {
            services.AddSingleton<IPackageSource, WingetSource>();
            services.AddSingleton<IPackageSource, NpmSource>();
            services.AddSingleton<IPackageSource, PipSource>();
            services.AddSingleton<IPackageSource, ChocoSource>();
            services.AddSingleton<SettingsService>();
            services.AddSingleton<MainViewModel>();
            services.AddSingleton<MainWindow>();
        })
        .Build();

    protected override async void OnStartup(StartupEventArgs e)
    {
        await AppHost.StartAsync();
        AppHost.Services.GetRequiredService<MainWindow>().Show();
        base.OnStartup(e);
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        using (AppHost)
        {
            await AppHost.StopAsync();
        }
        base.OnExit(e);
    }
}
