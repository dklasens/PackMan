using System.Diagnostics;
using System.Windows;
using PackMan.ViewModels;
using Wpf.Ui.Controls;

namespace PackMan;

public partial class SourcesWindow : FluentWindow
{
    public SourcesWindow(MainViewModel viewModel)
    {
        DataContext = viewModel;
        InitializeComponent();
    }

    private void Done_Click(object sender, RoutedEventArgs e) => Close();

    private void InstallationHelp_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is string url && Uri.TryCreate(url, UriKind.Absolute, out var uri))
            Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }
}
