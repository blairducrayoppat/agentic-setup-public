using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MinimalWinUI;

/// <summary>
/// The single window for the minimal template, pre-wired as a calculator SHELL.
///
/// NAMED HOOKS the staged coder extends (step 2 of the prompt -- theme the shell):
///   - `_calc` : the platform-free <see cref="Calculator"/> core, already constructed.
///   - `Display` : the readout TextBlock (x:Name in MainWindow.xaml) the handlers write to.
///   - `DemoButton_Click` : a worked example routing a button press THROUGH the core to
///     the Display. The coder swaps the single demo button for a real number/operator
///     grid and adds handlers that call _calc.Add/Subtract/Multiply/Divide -- the wiring
///     pattern is already shown, so it extends rather than re-authors it.
///
/// The XAML compiler, code-behind, event wiring, AND the core->Display path all build
/// and link from this seed, so the coder starts from a working calculator skeleton.
/// </summary>
public sealed partial class MainWindow : Window
{
    // The arithmetic core. UI handlers call into this -- they never do math themselves,
    // so the offline Tests/ harness can cover the behavior with no UI.
    private readonly Calculator _calc = new Calculator();

    public MainWindow()
    {
        this.InitializeComponent();
    }

    private void DemoButton_Click(object sender, RoutedEventArgs e)
    {
        // Worked example of the extend pattern: take operands, run them through the
        // core, show the result on the Display. The coder replaces this with handlers
        // driven by the real button grid (and surfaces Divide's exception nicely).
        var result = _calc.Add(2, 3);
        Display.Text = result.ToString();
    }
}
