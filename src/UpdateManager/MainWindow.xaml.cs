using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using UpdateManager.ViewModels;
using Wpf.Ui.Controls;

namespace UpdateManager;

public partial class MainWindow : FluentWindow
{
    private readonly MainViewModel _viewModel;

    public MainWindow(MainViewModel viewModel)
    {
        _viewModel = viewModel;
        DataContext = viewModel;
        InitializeComponent();

        ((INotifyCollectionChanged)_viewModel.LogLines).CollectionChanged += OnLogLinesChanged;
    }

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        if (_viewModel.ScanCommand.CanExecute(null))
            _viewModel.ScanCommand.Execute(null);
    }

    private void OnLogLinesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Add && _viewModel.LogLines.Count > 0)
        {
            LogList.ScrollIntoView(_viewModel.LogLines[^1]);
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_viewModel.IsBusy)
        {
            var result = System.Windows.MessageBox.Show(
                this,
                "A scan or update is still running. Close anyway?",
                "Update Manager",
                System.Windows.MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (result == System.Windows.MessageBoxResult.No)
            {
                e.Cancel = true;
                return;
            }
        }

        base.OnClosing(e);
    }
}
