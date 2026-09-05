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
    private bool _closingAfterCancellation;
    private bool _waitingToClose;

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

    private void Details_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.SelectedPackage = (sender as FrameworkElement)?.DataContext as PackageUpdate
            ?? UpdatesGrid.SelectedItem as PackageUpdate;
        new ActivityWindow(_viewModel) { Owner = this }.Show();
    }

    private void History_Click(object sender, RoutedEventArgs e) =>
        new ActivityWindow(_viewModel, history: true) { Owner = this }.Show();

    private void OnLogEntriesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Add && FollowLogCheck.IsChecked == true && _viewModel.LogEntries.Count > 0)
            LogList.ScrollIntoView(_viewModel.LogEntries[^1]);
    }

    protected override async void OnClosing(CancelEventArgs e)
    {
        if (_waitingToClose) { e.Cancel = true; return; }
        if (!_closingAfterCancellation && _viewModel.IsBusy && !_viewModel.IsApplyingAppUpdate)
        {
            var result = System.Windows.MessageBox.Show(this,
                "A scan or update is still running. Cancel it and close PackMan?", "PackMan",
                System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Warning);
            if (result == System.Windows.MessageBoxResult.No) { e.Cancel = true; return; }
            e.Cancel = true;
            _waitingToClose = true;
            await _viewModel.CancelAndWaitAsync();
            _waitingToClose = false;
            _closingAfterCancellation = true;
            _ = Dispatcher.BeginInvoke(new Action(Close));
            return;
        }
        _elapsedTimer.Stop();
        base.OnClosing(e);
    }
}
