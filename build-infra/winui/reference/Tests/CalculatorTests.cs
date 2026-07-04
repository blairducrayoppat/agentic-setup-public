namespace MinimalWinUI.Tests;

/// <summary>
/// OFFLINE, dependency-free tests for <see cref="Calculator"/>.
///
/// WHY THERE IS NO TEST FRAMEWORK HERE (read before "improving" this):
///   This machine is offline-first -- package restore succeeds ONLY from the local
///   feed, and MSTest / xUnit / NUnit are NOT in that feed. Referencing one fails
///   restore with NU1101 (the exact wall the parked run hit: it invented MSTest's
///   [TestMethod] -> CS0246, then spun a 2nd project to host it, and could not get a
///   framework working offline -> park). So these tests use a TINY in-file assert
///   harness (TestAssert below) that throws on failure and needs ZERO NuGet. They
///   build offline with a plain `dotnet build`, every time.
///
///   Do NOT add a [TestMethod] attribute, a `using Microsoft.VisualStudio.TestTools...`,
///   an `xunit`/`nunit` PackageReference, or a second/test .csproj. EXTEND this file:
///   add more `Check_*` methods and assertions. (The fleet's WinUI gate is a build
///   gate -- ADR-035 -- so the job of these tests is to COMPILE cleanly and document
///   the expected behavior; the operator runs RunAll() by hand to see them pass.)
///
/// Each Check_* method throws if an expectation fails; RunAll() invokes them all and
/// returns the number that passed (and rethrows the first failure). It is deliberately
/// NOT named Main and is NOT a static entry point -- the WinExe entry stays App.xaml.cs.
/// </summary>
public sealed class CalculatorTests
{
    private readonly Calculator _calc = new Calculator();

    // TODO: the coder ADDS more Check_* methods here as it implements the core --
    // one per behavior (e.g. Check_Chained_Operations, Check_Negative_Operands).
    // Keep them dependency-free: just call _calc and TestAssert.* (no NuGet).

    public void Check_Add()
    {
        TestAssert.AreEqual(5.0, _calc.Add(2, 3), "2 + 3");
        TestAssert.AreEqual(-1.0, _calc.Add(2, -3), "2 + (-3)");
    }

    public void Check_Subtract()
    {
        TestAssert.AreEqual(-1.0, _calc.Subtract(2, 3), "2 - 3");
    }

    public void Check_Multiply()
    {
        TestAssert.AreEqual(6.0, _calc.Multiply(2, 3), "2 * 3");
        TestAssert.AreEqual(0.0, _calc.Multiply(0, 3), "0 * 3");
    }

    public void Check_Divide()
    {
        TestAssert.AreEqual(2.0, _calc.Divide(6, 3), "6 / 3");
    }

    public void Check_Divide_By_Zero_Throws()
    {
        TestAssert.Throws<System.DivideByZeroException>(() => _calc.Divide(1, 0), "1 / 0");
    }

    /// <summary>
    /// Runs every Check_* test. Returns the count that passed; rethrows the first
    /// failure so a hand-run surfaces it. (The operator can call this from a scratch
    /// harness; the gate itself only needs this file to BUILD.)
    /// </summary>
    public int RunAll()
    {
        var passed = 0;
        Check_Add(); passed++;
        Check_Subtract(); passed++;
        Check_Multiply(); passed++;
        Check_Divide(); passed++;
        Check_Divide_By_Zero_Throws(); passed++;
        return passed;
    }
}

/// <summary>
/// Minimal, dependency-free assertion helpers -- the whole reason these tests build
/// offline. Each throws a plain <see cref="System.Exception"/> on failure (no NuGet).
/// Extend with more helpers (AreNotEqual, IsTrue, ...) as needed; keep it package-free.
/// </summary>
internal static class TestAssert
{
    public static void AreEqual(double expected, double actual, string because)
    {
        // A small tolerance so floating-point arithmetic does not cause spurious
        // failures (e.g. 0.1 + 0.2). Tighten/loosen as a test needs.
        if (System.Math.Abs(expected - actual) > 1e-9)
        {
            throw new System.Exception($"FAIL [{because}]: expected {expected}, got {actual}.");
        }
    }

    public static void Throws<TException>(System.Action action, string because)
        where TException : System.Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return; // expected
        }
        throw new System.Exception($"FAIL [{because}]: expected {typeof(TException).Name} to be thrown, but it was not.");
    }
}
