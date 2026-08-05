using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using PackMan.Models;
using PackMan.ViewModels;
using Wpf.Ui.Controls;

namespace PackMan;

public partial class MainWindow : FluentWindow
{
    private readonly MainViewModel _viewModel;
    private readonly DispatcherTimer _elapsedTimer;

    public MainWindow(MainViewModel viewModel)
    {
        _viewModel = viewModel;
        DataContext = viewModel;
        InitializeComponent();
        ((INotifyCollectionChanged)_viewModel.LogEntries).CollectionChanged += OnLogEntriesChanged;
        _elapsedTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background,
            (_, _) => { foreach (var source in _viewModel.SourceOptions) source.Refresh(); }, Dispatcher);
        _elapsedTimer.Start();
    }

    private void Sources_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.ReloadIgnored();
        new SourcesWindow(_viewModel) { Owner = this }.ShowDialog();
    }

    private void OnLogEntriesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Add && FollowLogCheck.IsChecked == true && _viewModel.LogEntries.Count > 0)
            LogList.ScrollIntoView(_viewModel.LogEntries[^1]);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_viewModel.IsBusy)
        {
            var result = System.Windows.MessageBox.Show(this,
                "A scan or update is still running. Cancel it and close PackMan?", "PackMan",
                System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Warning);
            if (result == System.Windows.MessageBoxResult.No) { e.Cancel = true; return; }
            _viewModel.ScanOrCancelCommand.Execute(null);
        }
        _elapsedTimer.Stop();
        base.OnClosing(e);
    }
}
