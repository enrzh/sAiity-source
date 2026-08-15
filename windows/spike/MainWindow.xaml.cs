using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Saiity.OverlaySpike;

public partial class MainWindow : Window
{
    private const int GwlExstyle = -20;
    private const int WsExLayered = 0x00080000;
    private const int WsExTransparent = 0x00000020;
    private const int WsExNoActivate = 0x08000000;
    private const int WsExToolWindow = 0x00000080;
    private const int WsExTopmost = 0x00000008;
    private const int DwmwaSystemBackdropType = 38;
    private const int DwmwbtTransientWindow = 3;

    public MainWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => ConfigureOverlay();
    }

    private void ConfigureOverlay()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var style = GetWindowLongPtr(handle, GwlExstyle).ToInt64();
        SetWindowLongPtr(handle, GwlExstyle, new IntPtr(
            style | WsExLayered | WsExTransparent | WsExNoActivate |
            WsExToolWindow | WsExTopmost));

        // E2: test whether the DWM backdrop survives the layered style.
        // The XAML surface remains a solid fallback if the OS backdrop is
        // absent; no gradient or animated fade is part of the product design.
        _ = DwmSetWindowAttribute(handle, DwmwaSystemBackdropType,
            ref UnsafeBackdropType, sizeof(int));
    }

    private static int UnsafeBackdropType = DwmwbtTransientWindow;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr handle, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr handle, int index, IntPtr value);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr handle, int attribute, ref int value, int valueSize);
}
