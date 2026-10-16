"""Fills the lookup columns of the seed records through the Web API, bypassing custom plug-ins.
`pac data import` does not set a lookup that points at a record from another seed package, so after loading
deploy/seed/phase1..phase7 in order, run this once. Usage: python repair-seed-lookups.py <org url> <token file> [--dry]
The seed ids in data.xml must be the ids in the target environment (see docs/phase10.md)."""
import re, json, os, sys, urllib.request, urllib.error

ORG = sys.argv[1]
TOKEN = open(sys.argv[2], encoding='utf-8').read().strip()
API = ORG + '/api/data/v9.2/'
SEED = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'deploy', 'seed')
DRY = '--dry' in sys.argv


def call(method, path, body=None, extra=None):
    h = {'Authorization': 'Bearer ' + TOKEN, 'Accept': 'application/json', 'OData-Version': '4.0'}
    if extra: h.update(extra)
    data = None
    if body is not None:
        data = json.dumps(body).encode(); h['Content-Type'] = 'application/json'
    req = urllib.request.Request(API + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read(); return json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        raise RuntimeError('%s %s -> %s %s' % (method, path, e.code, e.read().decode()[:300]))


setcache, navcache = {}, {}


def setname(e):
    if e not in setcache:
        setcache[e] = call('GET', "EntityDefinitions(LogicalName='%s')?$select=EntitySetName" % e)['EntitySetName']
    return setcache[e]


def navs(e):
    if e not in navcache:
        rels = call('GET', "EntityDefinitions(LogicalName='%s')/ManyToOneRelationships?$select=ReferencingAttribute,ReferencingEntityNavigationPropertyName" % e)['value']
        navcache[e] = {r['ReferencingAttribute']: r['ReferencingEntityNavigationPropertyName'] for r in rels}
    return navcache[e]


done = fail = 0
errors = []
for ph in ['phase%d' % i for i in range(1, 8)]:
    s = open('%s/%s/data.xml' % (SEED, ph), encoding='utf-8').read()
    for e in re.findall(r'<entity name="([^"]+)"', s):
        blk = re.search(r'<entity name="%s".*?</entity>' % e, s, re.S).group(0)
        n = 0
        for rid, body in re.findall(r'<record id="([^"]+)">(.*?)</record>', blk, re.S):
            binds = {}
            for attr, val, tgt in re.findall(r'<field name="([^"]+)" value="([^"]+)" lookupentity="([^"]+)"', body):
                nav = navs(e).get(attr)
                if not nav:
                    errors.append('%s.%s: no navigation property' % (e, attr)); continue
                binds[nav + '@odata.bind'] = '/%s(%s)' % (setname(tgt), val)
            if not binds: continue
            n += 1
            if DRY: continue
            try:
                call('PATCH', '%s(%s)' % (setname(e), rid), binds, {'MSCRM.BypassCustomPluginExecution': 'true', 'If-Match': '*'})
                done += 1
            except Exception as ex:
                fail += 1
                if len(errors) < 8: errors.append(str(ex)[:260])
        print(ph, e, 'records with lookups:', n, flush=True)
print('patched', done, 'failed', fail)
for x in sorted(set(errors))[:8]: print('  ', x)
