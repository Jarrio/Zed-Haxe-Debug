import utest.Runner;
import utest.ui.Report;

class TestMain {
	static function main() {
		bridge.Log.install();
		final runner = new Runner();
		runner.addCase(new PlanTest());
		runner.addCase(new FiltersTest());
		runner.onComplete.add(_ -> Fixture.removeAll());
		Report.create(runner);
		runner.run();
	}
}
