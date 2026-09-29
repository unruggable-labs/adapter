"""Read-only signing guards. Run after sourcing robinhood-signing-inputs.sh."""
import argparse,json,os,pathlib,re,subprocess,urllib.request
parser=argparse.ArgumentParser();parser.add_argument('--phase',choices=['initial','implementation','proxy'],required=True);phase=parser.parse_args().phase
P=pathlib.Path('output');expected=json.load(open(P/'robinhood-live-evidence.json'))
URL=os.environ['ROBINHOOD_RPC_URL'];SAFE=os.environ['SAFE'];IMPL=os.environ['VANITY_IMPL'];PROXY=os.environ['VANITY_PROXY'];REGISTRY=os.environ['REGISTRY'];SENDER=os.environ['PREM_DEPLOYER_ADDRESS'];FACTORY=os.environ['FACTORY']
SLOT='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
IMPL_HASH='0x89df8d1ddb712742b9d7bdfa4048cbcdb651e5abc204b8e1714f8a431c5dad90'
def cast(*args):return subprocess.check_output(['cast',*args],text=True).strip()
def raw(method,params):
 req=urllib.request.Request(URL,json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params)).encode(),headers={'Content-Type':'application/json','User-Agent':'Mozilla/5.0'})
 with urllib.request.urlopen(req,timeout=60) as response:return json.load(response)
def rpc(method,params):
 r=raw(method,params);assert 'error' not in r,r;return r['result']
def eq(a,b):assert a.lower()==b.lower(),(a,b)
def code(a):return rpc('eth_getCode',[a,b])
def storage(a,slot):return rpc('eth_getStorageAt',[a,slot,b])
def read(a,sig,*args):return cast('abi-decode',sig,rpc('eth_call',[{'to':a,'data':cast('calldata',sig,*args)},b]))
def empty(a):eq(code(a),'0x');assert int(rpc('eth_getTransactionCount',[a,b]),16)==0
assert rpc('eth_chainId',[])=='0x1237'
block=rpc('eth_getBlockByNumber',['latest',False]);b=block['number'];result={'phase':phase,'blockNumber':int(b,16),'blockHash':block['hash']}
for name,c in expected['contracts'].items():eq(cast('keccak',code(c['address'])),c['hash'])
eq('0x'+storage(REGISTRY,SLOT)[-40:],expected['contracts']['registryImplementation']['address'])
eq('0x'+storage(SAFE,'0x0')[-40:],expected['contracts']['singleton']['address'])
eq('0x'+storage(SAFE,'0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5')[-40:],expected['contracts']['fallback']['address'])
eq(storage(SAFE,'0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8'),'0x'+'00'*32)
eq(read(REGISTRY,'owner()(address)'),'0x547289319C3e6aedB179C0b8e8aF0B5ACd062603')
assert read(SAFE,'getThreshold()(uint256)')=='2'
assert read(SAFE,'nonce()(uint256)')=='0'
assert read(SAFE,'VERSION()(string)')=='"1.4.1"'
owners=read(SAFE,'getOwners()(address[])');assert set(re.findall(r'0x[0-9a-fA-F]{40}',owners.lower()))==set(re.findall(r'0x[0-9a-fA-F]{40}',expected['getOwners()(address[])'].lower()))
assert read(SAFE,'getModulesPaginated(address,uint256)(address[],address)','0x0000000000000000000000000000000000000001','100')==expected['modules']
nonce=int(rpc('eth_getTransactionCount',[SENDER,b]),16);balance=int(rpc('eth_getBalance',[SENDER,b]),16)
assert nonce=={'initial':0,'implementation':1,'proxy':2}[phase],('deployer nonce changed',nonce)
pending_nonce=int(rpc('eth_getTransactionCount',[SENDER,'pending']),16)
assert pending_nonce==nonce,('pending deployer transaction detected',pending_nonce)
result.update(deployerNonce=nonce,deployerBalanceWei=balance,safeThreshold=2,safeNonce=0)
if phase=='initial':empty(IMPL)
else:
 eq(cast('keccak',code(IMPL)),IMPL_HASH)
 eq(read(IMPL,'identityRegistry()(address)'),REGISTRY)
 eq(read(IMPL,'proxiableUUID()(bytes32)'),SLOT)
 r=raw('eth_call',[{'to':IMPL,'data':cast('calldata','initialize(address)',SAFE)},b])
 assert r.get('error',{}).get('data','').startswith(cast('sig','InvalidInitialization()')),r
if phase!='proxy':
 empty(PROXY)
 assert balance>0
else:
 eq(cast('keccak',code(PROXY)),'0xa9c092f12ac0cf28336ae9fc3aa7c6e11411d6dbbb033cedb4f41a93da2eb17a')
 eq('0x'+storage(PROXY,SLOT)[-40:],IMPL)
 eq(read(PROXY,'owner()(address)'),SAFE)
 eq(read(PROXY,'identityRegistry()(address)'),REGISTRY)
 r=raw('eth_call',[{'to':PROXY,'data':cast('calldata','initialize(address)',SAFE)},b])
 assert r.get('error',{}).get('data','').startswith(cast('sig','InvalidInitialization()')),r
result['passed']=True
path=P/('robinhood-preflight-'+phase+'.json');path.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));print('Read-only preflight passed; no transaction sent.')
