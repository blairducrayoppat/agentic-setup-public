namespace App;

// Core logic as a plain, PLATFORM-FREE class (no Android types) so it stays unit-testable on any
// runtime -- replace the placeholder Add with the real functionality. Keeping logic OUT of the
// Activity is what makes an Android app testable; the Activity should only wire UI to this.
public static class Calculator
{
    public static int Add(int a, int b) => a + b;
}
