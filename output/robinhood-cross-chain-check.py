import json,subprocess,pathlib
p=pathlib.Path('output');rh=json.load(open(p/'robinhood-live-evidence.json'))
def cast(*args):return subprocess.check_output(['cast',*args],text=True).strip()
result={}
for chain,rpc in [('base','https://base-rpc.publicnode.com'),('ethereum','https://ethereum-rpc.publicnode.com')]:
 b=cast('block-number','--rpc-url',rpc)
 row={'block':b,'blockHash':cast('block',b,'--field','hash','--rpc-url',rpc),'contracts':{}}
 safe=rh['contracts']['safe']['address']
 row['threshold']=cast('call',safe,'getThreshold()(uint256)','--block',b,'--rpc-url',rpc);assert row['threshold']=='3'
 row['owners']=cast('call',safe,'getOwners()(address[])','--block',b,'--rpc-url',rpc);assert row['owners'].lower()==rh['getOwners()(address[])'].lower()
 for name in ['safe','singleton','fallback','factory','delegate']:
  addr=rh['contracts'][name]['address'];code=cast('code',addr,'--block',b,'--rpc-url',rpc);h=cast('keccak',code)
  assert h==rh['contracts'][name]['hash'],(chain,name,h)
  row['contracts'][name]={'address':addr,'hash':h}
 result[chain]=row
p.joinpath('robinhood-cross-chain-evidence.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
