using System.Diagnostics;
using System.Windows;
using PackMan.ViewModels;
using Wpf.Ui.Controls;

namespace PackMan;

public partial class SourcesWindow : FluentWindow
{
    private readonly MainViewModel _viewModel;
    public SourcesWindow(MainViewModel viewModel)
    {
        _viewModel = viewModel;
        DataContext = viewModel;
        InitializeComponent();
        Loaded += (_, _) => Services.UiTestEnvironment.CaptureWindow(this, "cache-preview.png");
        SizeChanged += (_, _) => Services.UiTestEnvironment.CaptureWindow(this, "cache-preview.png");
        SourcesScroll.ScrollChanged += (_, _) => Services.UiTestEnvironment.CaptureWindow(this, "cache-preview.png");
        viewModel.PropertyChanged += OnViewModelChanged;
        Closed += (_, _) => viewModel.PropertyChanged -= OnViewModelChanged;
    }

    private void OnViewModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainViewModel.IsBusy) && !_viewModel.IsBusy)
            Services.UiTestEnvironment.CaptureWindow(this, "cache-preview.png");
    }

    private void Done_Click(object sender, RoutedEventArgs e) => Close();

    private void InstallationHelp_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is string url && Uri.TryCreate(url, UriKind.Absolute, out var uri))
            Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }
}
