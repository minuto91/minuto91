"""Roda casos JSON no protótipo V7.7 (v77_engine.py) SEM alterar o protótipo.
Uso: python3 -I run_cases.py casos.json  -> imprime JSON com as linhas de cada caso.
Também reexecuta as 21 checagens do protótipo (v77_validation.json) e o valor do atacante (LET 91,60...).
v72_corrected.py cria /mnt/data/min91audit ao ser importado; aqui o mkdir vira no-op só durante o import."""
import json, sys, pathlib
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
_mk = pathlib.Path.mkdir
pathlib.Path.mkdir = lambda self, *a, **k: None
import v77_engine as V  # noqa: E402
pathlib.Path.mkdir = _mk


def ev(c):
    return V.mk(q=c.get('q'), goals=c.get('goals'), assists=c.get('assists'), conceded=c.get('conceded'),
                saves=c.get('saves'), result=c.get('result'), yellow=c.get('yellow', 0), red=c.get('red', 0),
                played=c.get('played', True), resenha_votes=c.get('resenha_votes'))


def run(case):
    seasons = case['seasons']
    prev = None
    out = []
    for s in seasons:
        rows = V.evaluate([ev(c) for c in s], case['position'], 3, prev)
        out.append([{k: r[k] for k in ('DEF', 'SECOND', 'APR', 'RES', 'DIS', 'internal_ovr', 'played_games')} | {'evidence': r['evidence']} for r in rows])
        if any(c.get('played', True) for c in s):
            prev = V.prior_payload(rows)
    return out


if __name__ == '__main__':
    cases = json.loads(pathlib.Path(sys.argv[1]).read_text())
    checks = V.checks()
    striker = V.evaluate([V.mk(goals=1, q=9)] * 10, 'ATA')[-1]['SECOND']
    print(json.dumps({'results': [run(c) for c in cases], 'checks': checks, 'striker_let': striker}))
