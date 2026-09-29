"""Independently rebuild the exact Sourcify registry sources with their original compiler.
Usage: python3 output/verify-robinhood-registry.py [--offline]
Requires ~/.svm/0.8.24/solc-0.8.24 or SOLC_0824; never changes Adapter compiler/dependencies.
"""
import argparse,json,os,pathlib,subprocess,urllib.request
args=argparse.ArgumentParser();args.add_argument('--offline',action='store_true');offline=args.parse_args().offline
p=pathlib.Path('output');url='https://sourcify.dev/server/v2/contract/4663/0x7274e874ca62410a93bd8bf61c69d8045e399c02?fields=all'
if not offline:
 with urllib.request.urlopen(url,timeout=60) as response:x=json.load(response)
 p.joinpath('robinhood-source-0.json').write_text(json.dumps(x,indent=2)+'\n')
else:x=json.load(open(p/'robinhood-source-0.json'))
assert x['runtimeMatch']=='exact_match' and str(x['chainId'])=='4663'
assert x['address'].lower()=='0x7274e874ca62410a93bd8bf61c69d8045e399c02'
compiler=os.environ.get('SOLC_0824',str(pathlib.Path.home()/'.svm/0.8.24/solc-0.8.24'))
assert '0.8.24+commit.e11b9ed9' in subprocess.check_output([compiler,'--version'],text=True)
std=x['stdJsonInput'];std['settings']['outputSelection']={'*':{'*':['evm.deployedBytecode']}}
p.joinpath('robinhood-registry-solc-input.json').write_text(json.dumps(std)+'\n')
compiled=subprocess.check_output([compiler,'--standard-json'],input=json.dumps(std),text=True)
p.joinpath('robinhood-registry-solc-output.json').write_text(compiled)
out=json.loads(compiled);assert not [e for e in out.get('errors',[]) if e['severity']=='error']
c=out['contracts']['project/contracts/IdentityRegistryUpgradeable.sol']['IdentityRegistryUpgradeable']['evm']['deployedBytecode'];code=bytearray.fromhex(c['object'])
for refs in c['immutableReferences'].values():
 for ref in refs:code[ref['start']:ref['start']+ref['length']]=bytes.fromhex('7274e874ca62410a93bd8bf61c69d8045e399c02'.zfill(64))
live=(p/'robinhood-registryImplementation-runtime.hex').read_text().strip()
assert x['runtimeBytecode']['onchainBytecode'].lower()==live.lower()
assert '0x'+code.hex()==live
h=subprocess.check_output(['cast','keccak',live],text=True).strip()
assert h=='0xa5f9624ea85e45b3f4b8558581f03bfb3e6cefab278d7bf0500ec9bd065dc16f'
summary={'source':url,'compiler':x['compilation'],'runtimeHash':h,'exactLocalRebuildMatch':True,'immutableSelf':'0x7274e874ca62410a93bd8bf61c69d8045e399c02'}
proxy_url='https://sourcify.dev/server/v2/contract/4663/0x8004A169FB4a3325136EB29fA0ceB6D2e539a432?fields=all'
if not offline:
 with urllib.request.urlopen(proxy_url,timeout=60) as response:px=json.load(response)
 p.joinpath('robinhood-registry-proxy-source.json').write_text(json.dumps(px,indent=2)+'\n')
else:px=json.load(open(p/'robinhood-registry-proxy-source.json'))
assert px['runtimeMatch']=='exact_match' and px['compilation']['compilerVersion']=='0.8.24+commit.e11b9ed9'
pstd=px['stdJsonInput'];pstd['settings']['outputSelection']={'*':{'*':['evm.deployedBytecode']}}
pc=json.loads(subprocess.check_output([compiler,'--standard-json'],input=json.dumps(pstd),text=True))
proxy_code=pc['contracts']['project/contracts/ERC1967Proxy.sol']['ERC1967Proxy']['evm']['deployedBytecode']
assert not proxy_code.get('immutableReferences')
proxy_live=(p/'robinhood-registry-runtime.hex').read_text().strip()
assert '0x'+proxy_code['object']==proxy_live
assert px['runtimeBytecode']['onchainBytecode'].lower()==proxy_live.lower()
summary['proxy']={'source':proxy_url,'exactLocalRebuildMatch':True,'runtimeHash':subprocess.check_output(['cast','keccak',proxy_live],text=True).strip()}
p.joinpath('robinhood-registry-rebuild.json').write_text(json.dumps(summary,indent=2)+'\n')
print('Registry implementation and proxy rebuilds EXACT MATCH including metadata; only implementation immutable self patched.')
