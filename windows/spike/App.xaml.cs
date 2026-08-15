using System.Windows;

namespace Saiity.OverlaySpike;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        new MainWindow { Left = 80, Top = 80 }.Show();
    }
}
