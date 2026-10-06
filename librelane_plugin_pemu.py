"""Project steps for LibreLane.

LibreLane loads modules named librelane_plugin_* from the working directory, which is the repo
root in the Tiny Tapeout flow. src/config.json runs Pemu.BridgeSramPower right after the power
grid is generated.
"""

import json
import os
import re

import librelane.steps.netgen as netgen
from librelane.steps import Step
from librelane.steps.odb import OdbpyStep

HERE = os.path.dirname(os.path.abspath(__file__))


@Step.factory.register()
class BridgeSramPower(OdbpyStep):
    id = "Pemu.BridgeSramPower"
    name = "Connect SRAM power columns to the grid"

    def get_script_path(self):
        return os.path.join(HERE, "scripts", "bridge_sram_power.py")


# Netgen writes SRAM pin names like VDD! as "\VDD!" in its JSON report, which json.loads
# rejects. Double any backslash that doesn't start a valid JSON escape before parsing.
_stray_backslash = re.compile(r'\\(?![\\"/bfnrtu])')


class _NetgenJson:
    def __getattr__(self, name):
        return getattr(json, name)

    @staticmethod
    def loads(text, *args, **kwargs):
        return json.loads(_stray_backslash.sub(r"\\\\", text), *args, **kwargs)


netgen.json = _NetgenJson()
