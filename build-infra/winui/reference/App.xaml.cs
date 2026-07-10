using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace MinimalWinUI;

/// <summary>
/// Application entry point, offline self-test entry, AND headless render entry.
///
/// The static Main below REPLACES the SDK-generated entry (DISABLE_XAML_GENERATED_MAIN
/// in MinimalWinUI.csproj). Three modes:
///
///   App.exe --test
///       -> run CalculatorTests.RunAll(), print + write PASS/FAIL to test-results.txt,
///          and EXIT 0 (all passed) or 1 (a check failed). Opens NO window.
///
///   App.exe --render-to-file &lt;path.png&gt;
///       -> Create the window positioned off-screen (never activated/foregrounded),
///          render MainWindow's root content via RenderTargetBitmap, write PNG to
///          &lt;path.png&gt;, exit 0 on success / 1 on failure (with a stderr message).
///          The window is hidden via SetWindowPos before Show, so it never appears
///          in the taskbar or steals focus. See FOCUS-STEAL NOTE below.
///
///   App.exe          (no args)
///       -> launch the WinUI app normally.
///
/// FOCUS-STEAL NOTE (--render-to-file):
///   WinUI 3 Desktop (Win32-hosted) requires a live visual tree with a valid
///   compositor for RenderTargetBitmap to produce pixels. This means a Window
///   MUST be created. We position it at (-32000, -32000) via SetWindowPos BEFORE
///   calling Show(), keeping it off any monitor. We call Show() rather than
///   Activate() -- Show() makes the HWND visible to the compositor without
///   requesting foreground input focus. In practice on the build machine the window
///   is invisible (off-screen) and the active foreground window is never disturbed.
///   This is NOT a fully invisible/server-side render -- it is a minimal-visibility
///   approach (window exists, compositor runs, no pixel appears on any display,
///   focus not stolen). The live pixel-proof is an on-hardware step.
///
/// The Main lives HERE because App.xaml.cs is the structural contract's ALLOWED entry
/// point -- a separate Program.cs with a Main is the proliferation signature the gate
/// forbids (see Test-ProjectStructure). The coder THEMES and WIRES MainWindow; it does
/// NOT touch this file.
/// </summary>
public partial class App : Application
{
    private Window? _window;

    // The render output path when running --render-to-file. Set before Application.Start
    // so OnLaunched can read it on the UI thread.
    private static string? _renderOutputPath;

    // Win32 imports for off-screen window positioning.
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    private const int SW_SHOWNOACTIVATE = 4;  // show without stealing focus
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;

    // Console attach for the guard/test/render messages (#684): a WinExe has NO attached
    // console, so System.Console writes go to a detached stream `dotnet run` never shows.
    // The live effect: the headless-build guard's "do NOT launch the app" guidance was
    // invisible to the coder, which retried `dotnet run` 7x in one build.
    [DllImport("kernel32.dll")] private static extern bool AttachConsole(int dwProcessId);
    private const int ATTACH_PARENT_PROCESS = -1;

    /// <summary>
    /// Attach to the parent process's console (if any) so Console.WriteLine reaches the
    /// invoker (`dotnet run`, a coder's shell). MUST run before the FIRST System.Console
    /// use: .NET binds Console.Out lazily, so attaching first makes the lazy init pick up
    /// the attached console with no stream re-opening. Fail-soft by design: launched from
    /// Explorer (no parent console) or already attached, the call fails and nothing
    /// changes -- the GUI path is unaffected, and test-results.txt remains the durable
    /// fallback channel for --test.
    /// </summary>
    static void TryAttachParentConsole()
    {
        try { AttachConsole(ATTACH_PARENT_PROCESS); } catch { /* best-effort */ }
    }

    [System.STAThread]
    static int Main(string[] args)
    {
        TryAttachParentConsole();  // #684: before ANY Console use (see the helper's doc)

        // OFFLINE SELF-TEST MODE: run the dependency-free Calculator tests and exit. No GUI.
        if (System.Array.IndexOf(args, "--test") >= 0)
        {
            try
            {
                int passed = new MinimalWinUI.Tests.CalculatorTests().RunAll();
                ReportTestResult($"PASS: all {passed} checks passed.", isError: false);
                return 0;
            }
            catch (System.Exception ex)
            {
                ReportTestResult($"FAIL: {ex.Message}", isError: true);
                return 1;
            }
        }

        // HEADLESS RENDER MODE: render the app's main content to a PNG and exit.
        int rtfIdx = System.Array.IndexOf(args, "--render-to-file");
        if (rtfIdx >= 0)
        {
            if (rtfIdx + 1 >= args.Length || string.IsNullOrWhiteSpace(args[rtfIdx + 1]))
            {
                System.Console.Error.WriteLine("RENDER-ERROR: --render-to-file requires a path argument.");
                return 1;
            }
            _renderOutputPath = args[rtfIdx + 1];
        }

        // HEADLESS-BUILD GUARD (2026-06-25): in the dispatch's headless build environment there is no
        // display and the coder is BLIND (only the post-merge VLM critique sees the UI). A no-args GUI
        // launch there only HANGS the coder's `dotnet run` (a WinUI window never exits) -- a major cause
        // of build timeouts -- and can pop a runtime dialog at the operator. When the dispatch marks
        // this a headless build (BLARAI_HEADLESS_BUILD) AND we are not rendering, do NOT launch the GUI:
        // print guidance and exit 0. Invisible to --test (handled above), to --render-to-file (sets
        // _renderOutputPath, so skipped here), and to the real operator launch (no env var -> GUI runs).
        if (_renderOutputPath is null &&
            !string.IsNullOrEmpty(System.Environment.GetEnvironmentVariable("BLARAI_HEADLESS_BUILD")))
        {
            System.Console.WriteLine(
                "[dispatch guard] The app was NOT launched: this is a headless build with no display, and " +
                "you (the coder) cannot see the UI -- launching it only hangs your session and wastes your " +
                "time budget. Verify with `dotnet build` (it must compile with 0 errors) and `App.exe --test` " +
                "or `dotnet test` (the unit tests). Do NOT launch the app.");
            return 0;
        }

        // NORMAL GUI LAUNCH (also used by --render-to-file: both go through Application.Start
        // so the WinRT dispatcher and XAML compositor are initialized correctly).
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start((p) =>
        {
            var context = new Microsoft.UI.Dispatching.DispatcherQueueSynchronizationContext(
                Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
            System.Threading.SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
        return _renderExitCode;
    }

    // Exit code set by the render path on the UI thread; read after Application.Start returns.
    private static int _renderExitCode = 0;

    // Surface the test outcome on the console AND in test-results.txt. With the #684
    // parent-console attach the console line reaches `dotnet run` too, but the file stays
    // the DURABLE channel (no parent console -> the attach no-ops) and the process EXIT
    // CODE, 0 or 1, is always the source of truth for pass/fail.
    static void ReportTestResult(string text, bool isError)
    {
        if (isError) { System.Console.Error.WriteLine(text); } else { System.Console.WriteLine(text); }
        try { System.IO.File.WriteAllText("test-results.txt", text + System.Environment.NewLine); }
        catch { /* best-effort; the exit code still conveys pass/fail */ }
    }

    public App()
    {
        this.InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();

        if (_renderOutputPath is not null)
        {
            // RENDER PATH: position the window off-screen, never activate/foreground it,
            // render to PNG, then exit the app.
            _ = RenderAndExitAsync(_renderOutputPath);
        }
        else
        {
            // NORMAL PATH: activate the window normally.
            _window.Activate();
        }
    }

    private async System.Threading.Tasks.Task RenderAndExitAsync(string outputPath)
    {
        try
        {
            // Get the HWND so we can position the window before it becomes visible.
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(_window!);

            // Move window off-screen BEFORE showing it. (-32000, -32000) is the
            // Windows convention for "off every monitor". NOACTIVATE keeps the current
            // foreground window untouched.
            SetWindowPos(hwnd, IntPtr.Zero, -32000, -32000, 800, 600,
                SWP_NOZORDER | SWP_NOACTIVATE);

            // SW_SHOWNOACTIVATE: make the HWND compositor-visible without stealing focus.
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);

            // Give the XAML layout pass a moment to measure and arrange the content.
            // WinUI 3 async layout: the first few frames after Show() may still be
            // measuring; 300 ms is sufficient for a simple layout with no async data.
            await System.Threading.Tasks.Task.Delay(300);

            // Find the root element to render. The Window's Content is the root UIElement.
            var root = _window!.Content as Microsoft.UI.Xaml.UIElement;
            if (root is null)
            {
                System.Console.Error.WriteLine("RENDER-ERROR: window Content is null; nothing to render.");
                _renderExitCode = 1;
                Application.Current.Exit();
                return;
            }

            // RenderTargetBitmap captures the element's current visual state.
            var rtb = new RenderTargetBitmap();
            await rtb.RenderAsync(root);

            // Extract pixels (BGRA8) and encode as PNG via BitmapEncoder.
            var pixelBuffer = await rtb.GetPixelsAsync();
            uint width = (uint)rtb.PixelWidth;
            uint height = (uint)rtb.PixelHeight;

            if (width == 0 || height == 0)
            {
                System.Console.Error.WriteLine(
                    "RENDER-ERROR: RenderTargetBitmap returned 0x0 pixels. " +
                    "This indicates the element was not in a live, measured visual tree. " +
                    "The window may need to be shown (activated) before a non-zero render is possible.");
                _renderExitCode = 1;
                Application.Current.Exit();
                return;
            }

            // Write PNG via BitmapEncoder to a file.
            var outDir = System.IO.Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrEmpty(outDir))
                System.IO.Directory.CreateDirectory(outDir);

            using var stream = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(
                BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                width, height,
                96, 96, // nominal DPI -- actual display DPI not needed for VLM critique
                pixelBuffer.ToArray());
            await encoder.FlushAsync();

            // Copy from the in-memory stream to the output file.
            stream.Seek(0);
            var reader = new DataReader(stream);
            await reader.LoadAsync((uint)stream.Size);
            byte[] pngBytes = new byte[stream.Size];
            reader.ReadBytes(pngBytes);
            await System.IO.File.WriteAllBytesAsync(outputPath, pngBytes);

            System.Console.WriteLine($"RENDER-OK: {width}x{height} -> {outputPath}");
            _renderExitCode = 0;
        }
        catch (System.Exception ex)
        {
            System.Console.Error.WriteLine($"RENDER-ERROR: {ex.GetType().Name}: {ex.Message}");
            _renderExitCode = 1;
        }
        finally
        {
            Application.Current.Exit();
        }
    }
}
