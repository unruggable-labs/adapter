import json,subprocess,pathlib,urllib.request
P=pathlib.Path('output'); URL='https://rpc.mainnet.chain.robinhood.com'
def cast(*args):return subprocess.check_output(['cast',*args],text=True).strip()
def rpc(method,params):
 req=urllib.request.Request(URL,json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params)).encode(),headers={'Content-Type':'application/json','User-Agent':'Mozilla/5.0'})
 with urllib.request.urlopen(req,timeout=90) as r: out=json.load(r)
 if 'error' in out: raise Exception(out)
 return out['result']
def call(addr,sig,block):return rpc('eth_call',[{'to':addr,'data':cast('calldata',sig)},block])
safe='0x03302Df40186D9B85faEA4fbb6cC5da028B23149';reg='0x8004A169FB4a3325136EB29fA0ceB6D2e539a432';factory='0x4e59b44847b379578588920cA78FbF26c0B4956C';sender='0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF'
slot='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
import os
block=rpc('eth_getBlockByNumber',[os.environ.get('ROBINHOOD_SNAPSHOT_BLOCK','latest'),False]);b=block['number']; evidence={'block':block,'chainId':rpc('eth_chainId',[])}
assert evidence['chainId']=='0x1237'
regimpl='0x'+rpc('eth_getStorageAt',[reg,slot,b])[-40:];singleton='0x'+rpc('eth_getStorageAt',[safe,'0x0',b])[-40:]
fallback='0x'+rpc('eth_getStorageAt',[safe,'0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5',b])[-40:]
addresses={'safe':safe,'registry':reg,'registryImplementation':regimpl,'factory':factory,'delegate':'0x00000000000000447e69651d841bD8D104Bed493','singleton':singleton,'fallback':fallback}
evidence['contracts']={}
for name,addr in addresses.items():
 code=rpc('eth_getCode',[addr,b]);evidence['contracts'][name]={'address':addr,'bytes':(len(code)-2)//2,'hash':cast('keccak',code)}
 P.joinpath('robinhood-'+name+'-runtime.hex').write_text(code+'\n')
for sig in ['getOwners()(address[])','getThreshold()(uint256)','nonce()(uint256)','VERSION()(string)']:
 evidence[sig]=cast('abi-decode',sig,call(safe,sig,b))
evidence['modules']=cast('abi-decode','getModulesPaginated(address,uint256)(address[],address)',rpc('eth_call',[{'to':safe,'data':cast('calldata','getModulesPaginated(address,uint256)','0x0000000000000000000000000000000000000001','100')},b]))
evidence['guard']=rpc('eth_getStorageAt',[safe,'0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8',b])
evidence['deployer']={'address':sender,'balance':rpc('eth_getBalance',[sender,b]),'nonce':rpc('eth_getTransactionCount',[sender,b])}
evidence['arbOSVersion']=cast('abi-decode','arbOSVersion()(uint256)',call('0x0000000000000000000000000000000000000064','arbOSVersion()(uint256)',b))
assert evidence['getThreshold()(uint256)']=='2'; assert evidence['nonce()(uint256)']=='0'
P.joinpath('robinhood-live-evidence.json').write_text(json.dumps(evidence,indent=2)+'\n');print(json.dumps(evidence,indent=2))
implcreation=subprocess.check_output(['forge','inspect','src/AdapterImplementation.sol:AdapterImplementation','bytecode'],text=True).strip()
proxycreation=subprocess.check_output(['forge','inspect','ERC1967Proxy','bytecode'],text=True).strip()
implinit=implcreation+cast('abi-encode','f(address)',reg)[2:]
assert cast('keccak',implinit)=='0x5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558'
impl='0x'+cast('keccak','0xff'+factory[2:]+'00'*32+cast('keccak',implinit)[2:])[-40:]
assert impl.lower()=='0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231'.lower()
proxyinit=proxycreation+cast('abi-encode','f(address,bytes)',impl,cast('calldata','initialize(address)',safe))[2:]
assert cast('keccak',proxyinit)=='0xbb43a76de1130e845b39e4d6ff11934b8ccf9b4aae11084e955d7f7219cc9953'
for name,data in [('impl',implinit),('proxy',proxyinit)]:P.joinpath('robinhood-'+name+'-init.hex').write_text(data+'\n')
assert rpc('eth_getCode',[impl,b])=='0x';assert int(rpc('eth_getTransactionCount',[impl,b]),16)==0
# Exact implementation constructor executes remotely, with no state changes.
impltx={'from':sender,'data':implinit,'value':'0x0'}
directruntime=rpc('eth_call',[impltx,b])
artifact=json.load(open('out/AdapterImplementation.sol/AdapterImplementation.json'))['deployedBytecode']
compiled=bytearray.fromhex(artifact['object'][2:]);direct=bytes.fromhex(directruntime[2:])
refs=artifact['immutableReferences'];covered=set()
for group in refs.values():
 values={direct[r['start']:r['start']+r['length']] for r in group};assert len(values)==1
 value=values.pop(); patched=bytes.fromhex((reg if value.hex()[-40:]==reg[2:].lower() else impl)[2:].lower().zfill(64))
 for r in group:
  compiled[r['start']:r['start']+r['length']]=patched
  covered.update(range(r['start'],r['start']+r['length']))
raw=bytes.fromhex(artifact['object'][2:]);assert all(raw[i]==direct[i] for i in range(len(raw)) if i not in covered)
implruntime='0x'+compiled.hex();P.joinpath('robinhood-expected-impl-runtime.hex').write_text(implruntime+'\n')
results={'blockNumber':b,'blockHash':block['hash'],'implementation':impl,'implementationRuntimeHash':cast('keccak',implruntime),'implementationCreationEstimate':rpc('eth_estimateGas',[impltx,b])}
factorytx={'from':sender,'to':factory,'data':'0x'+'00'*32+implinit[2:],'value':'0x0'}
results['implementationFactoryResult']=rpc('eth_call',[factorytx,b]);results['implementationFactoryEstimate']=rpc('eth_estimateGas',[factorytx,b])
# The implementation is not deployed yet; only its independently reconstructed runtime is overlaid.
override={impl:{'code':implruntime}}
proxytx={'from':sender,'data':proxyinit,'value':'0x0'}
proxyruntime=rpc('eth_call',[proxytx,b,override]);results['proxyCreationRuntimeHash']=cast('keccak',proxyruntime)
results['proxyCreationEstimate']=rpc('eth_estimateGas',[proxytx,b,override])
salt='00'*31+'2a';pred='0x'+cast('keccak','0xff'+factory[2:]+salt+cast('keccak',proxyinit)[2:])[-40:]
factorytx['data']='0x'+salt+proxyinit[2:]
results['proxyFactoryResult']=rpc('eth_call',[factorytx,b,override]);results['proxyFactoryEstimate']=rpc('eth_estimateGas',[factorytx,b,override]);results['rehearsalSalt']='0x'+salt;results['rehearsalProxy']=pred
assert results['proxyFactoryResult'].lower()=='0x'+pred[2:].lower()
P.joinpath('robinhood-remote-creation.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
