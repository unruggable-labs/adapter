import json,os,pathlib,subprocess,urllib.request
P=pathlib.Path('output');e=json.load(open(P/'robinhood-live-evidence.json'));req=urllib.request.Request('https://rpc.mainnet.chain.robinhood.com',json.dumps({'jsonrpc':'2.0','id':1,'method':'eth_getBlockByNumber','params':['latest',False]}).encode(),headers={'Content-Type':'application/json','User-Agent':'Mozilla/5.0'})
with urllib.request.urlopen(req,timeout=60) as r:block=json.load(r)['result']
b=block['number']
def cast(*args):return subprocess.check_output(['cast',*args],text=True).strip()
salt=os.environ.get('PROXY_SALT','0x'+'00'*31+'2a')
subprocess.run(['forge','build','output/RobinhoodRemoteProbe.sol'],check=True)
implcode=json.load(open('out/AdapterImplementation.sol/AdapterImplementation.json'))['bytecode']['object']
proxycode=json.load(open('out/ERC1967Proxy.sol/ERC1967Proxy.json'))['bytecode']['object']
implinit=implcode+cast('abi-encode','f(address)','0x8004A169FB4a3325136EB29fA0ceB6D2e539a432')[2:]
proxyinit=proxycode+cast('abi-encode','f(address,bytes)','0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231',cast('calldata','initialize(address)','0x03302Df40186D9B85faEA4fbb6cC5da028B23149'))[2:]
args=cast('abi-encode','f(bytes,bytes,bytes32)',implinit,proxyinit,salt)
data=json.load(open('out/RobinhoodRemoteProbe.sol/RobinhoodRemoteProbe.json'))['bytecode']['object']+args[2:]
assert len(bytes.fromhex(data[2:]))<49152
transaction={'from':e['deployer']['address'],'data':data,'value':'0x0'}
result={'blockNumber':int(b,16),'blockHash':block['hash'],'stateOverrides':False,'proxySalt':salt,'probeInitCodeHash':cast('keccak',data),'probeInitCodeBytes':(len(data)-2)//2}
for method in ['eth_call','eth_estimateGas']:
 req=urllib.request.Request('https://rpc.mainnet.chain.robinhood.com',json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':[transaction,b]}).encode(),headers={'Content-Type':'application/json','User-Agent':'Mozilla/5.0'})
 with urllib.request.urlopen(req,timeout=90) as r:response=json.load(r)
 assert 'error' not in response,response
 result[method]=response['result']
result['decoded']=cast('abi-decode','f()(address,address,uint256,bytes32,bytes32)',result['eth_call'])
assert result['decoded'].splitlines()[0]=='0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231'
assert result['decoded'].splitlines()[4]=='0x89df8d1ddb712742b9d7bdfa4048cbcdb651e5abc204b8e1714f8a431c5dad90'
result['passed']=True
(P/'robinhood-remote-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
