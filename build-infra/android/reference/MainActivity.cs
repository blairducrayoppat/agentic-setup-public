namespace App;

// Entry-point Activity (MainLauncher). Keep UI wiring here; keep real logic in plain testable
// classes like Calculator. Extend OnCreate to build the real screen.
[Activity(Label = "@string/app_name", MainLauncher = true)]
public class MainActivity : Activity
{
    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        SetContentView(Resource.Layout.activity_main);

        // Example: drive the UI from the testable logic class (extend Calculator + this wiring).
        Title = $"2 + 3 = {Calculator.Add(2, 3)}";
    }
}
