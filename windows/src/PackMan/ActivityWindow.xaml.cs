using System.Windows;
using PackMan.ViewModels;
using Wpf.Ui.Controls;

namespace PackMan;

public partial class ActivityWindow : FluentWindow
{
    public ActivityWindow(MainViewModel viewModel, bool history = false)
    {
        DataContext = viewModel;
        InitializeComponent();
        ActivityTabs.SelectedIndex = history ? 1 : 0;
        Loaded += (_, _) => Capture();
        ActivityTabs.SelectionChanged += (_, _) => Capture();
    }
    private void Capture() => Services.UiTestEnvironment.CaptureWindow(this,
        ActivityTabs.SelectedIndex == 1 ? "update-history.png" : "package-details.png");
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
