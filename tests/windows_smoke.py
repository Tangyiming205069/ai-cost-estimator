"""Run on a Windows runner with synthetic data only; no user history access."""
import json,sys,tempfile,tkinter as tk
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
from engine import Engine
from windows_app import Window
with tempfile.TemporaryDirectory() as d:
    engine=Engine(d);engine.mode='demo'
    root=tk.Tk();ui=Window(root,Path(d)/'ui',start_backend=False)
    snapshot=engine.snapshot({});ui.render(snapshot);ui.toggle();root.update()
    assert len(ui.table.get_children())==len(snapshot['rows'])
    ui.table.selection_set('0');ui.details();assert ui.detail.get('1.0','end').strip()
    fast=engine.snapshot({'month':snapshot['month'],'speed':'fast'});ui.render(fast);root.update()
    assert not ui.table.get_children()
    ui.language();ui.toggle();root.update();ui.close();engine.close()
    assert json.loads((Path(d)/'ui/windows-ui.json').read_text())['language']=='zh'
print('Windows Tk window, filters, details, language and close passed with synthetic data.')
