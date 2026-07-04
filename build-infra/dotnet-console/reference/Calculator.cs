namespace App;

// Core logic kept in a class so it is unit-testable (the entry point stays thin). Replace/extend
// the placeholder Add with the task's real functionality, and add a matching test.
public static class Calculator
{
    public static int Add(int a, int b) => a + b;
}
