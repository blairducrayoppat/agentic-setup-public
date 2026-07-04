namespace MinimalWinUI;

/// <summary>
/// Platform-free arithmetic CORE for the minimal WinUI calculator template.
///
/// This class holds ZERO UI -- it is the testable logic the staged coder prompt
/// implements FIRST (step 1: make the core correct, extend the tests in Tests/),
/// BEFORE theming the MainWindow shell (step 2). Keeping the math here (not in the
/// code-behind) is what lets the offline test harness exercise it with no UI and
/// no NuGet package.
///
/// It COMPILES AS-IS so the seed builds 0/0: every method already returns a value.
/// The `// TODO:` slots mark where the coder fills in / extends real behavior --
/// the four ops are implemented as the obvious one-liners (a working baseline the
/// coder refines), and divide-by-zero is handled explicitly (the one edge case a
/// from-scratch author most often drops).
/// </summary>
public sealed class Calculator
{
    // TODO: extend with any additional operations the product needs (percent,
    // sign-flip, memory, a running total, etc.). Keep each one a pure method that
    // takes its operands and returns the result, so the Tests/ harness can cover it.

    /// <summary>Adds two numbers.</summary>
    public double Add(double a, double b)
    {
        // TODO: the coder may extend this (e.g. accumulate into a running total).
        return a + b;
    }

    /// <summary>Subtracts <paramref name="b"/> from <paramref name="a"/>.</summary>
    public double Subtract(double a, double b)
    {
        return a - b;
    }

    /// <summary>Multiplies two numbers.</summary>
    public double Multiply(double a, double b)
    {
        return a * b;
    }

    /// <summary>
    /// Divides <paramref name="a"/> by <paramref name="b"/>. Divide-by-zero is an
    /// explicit error rather than returning Infinity/NaN, so the UI can show a
    /// friendly message. The coder decides how the shell surfaces this.
    /// </summary>
    public double Divide(double a, double b)
    {
        // TODO: the coder wires the shell to catch this and show "Cannot divide by zero".
        if (b == 0)
        {
            throw new System.DivideByZeroException("Cannot divide by zero.");
        }
        return a / b;
    }
}
