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


# Netgen writes names like VDD! or uio_in as "\VDD!" / "\uio_in" in its JSON report, which
# json.loads rejects. Keep real JSON escapes as they are and double any other backslash.
_backslash = re.compile(r'\\(u[0-9a-fA-F]{4}|["\\/bfnrt])?')


def _fix_escapes(text):
    return _backslash.sub(lambda m: m.group(0) if m.group(1) else "\\\\", text)


class _NetgenJson:
    def __getattr__(self, name):
        return getattr(json, name)

    @staticmethod
    def loads(text, *args, **kwargs):
        return json.loads(_fix_escapes(text), *args, **kwargs)


netgen.json = _NetgenJson()
