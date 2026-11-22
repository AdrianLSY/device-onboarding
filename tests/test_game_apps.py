import json
from pathlib import Path
import runpy
import unittest
from unittest.mock import Mock, patch


class GameAppsTest(unittest.TestCase):
    def test_game_exit_restores_apps_that_were_closed_before_watcher_start(self):
        script = Path(__file__).resolve().parents[1] / "linux/hypr/scripts/game-apps"
        watch = runpy.run_path(str(script))["watch"]
        game = {"mapped": True, "contentType": "game", "class": "game", "initialClass": "game", "address": "0x1"}
        # The game opens, closes, then the compositor disconnects after the grace period.
        snapshots = map(json.dumps, [[], [game], [], []])
        events = Mock()
        events.recv.side_effect = [b"openwindow>>1\n", b"closewindow>>1\n",
                                   b"closewindow>>2\n", b""]
        launch = Mock()
        with patch.dict(watch.__globals__, output=lambda *args: next(snapshots),
                        flatpaks=set, cider_running=lambda: False, EXIT_GRACE=0), \
             patch("select.select", return_value=([events], [], [])), \
             patch("subprocess.Popen", launch):
            watch(events)
        self.assertCountEqual(
            [call.args[0] for call in launch.call_args_list],
            [["cider"]] + [["flatpak", "run", app] for app in (
                "com.bambulab.BambuStudio", "com.ultimaker.cura",
                "org.mozilla.thunderbird", "org.localsend.localsend_app",
            )],
        )


if __name__ == "__main__":
    unittest.main()
