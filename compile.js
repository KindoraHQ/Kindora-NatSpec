#!/usr/bin/env node

const solc = require('solc');
const fs = require('fs');
const path = require('path');

// Read contract files
const contractsDir = path.join(__dirname, 'contracts');
const kindoraNatSpec = fs.readFileSync(path.join(contractsDir, 'Kindora_NatSpec.sol'), 'utf8');
const kindora = fs.readFileSync(path.join(contractsDir, 'Kindora.sol'), 'utf8');

// Read mocks
const mocksDir = path.join(contractsDir, 'mocks');
const mockFactory = fs.readFileSync(path.join(mocksDir, 'MockFactory.sol'), 'utf8');
const mockRouter = fs.readFileSync(path.join(mocksDir, 'MockRouter.sol'), 'utf8');
const dummyERC20 = fs.readFileSync(path.join(mocksDir, 'DummyERC20.sol'), 'utf8');

// Prepare input for compiler
const input = {
  language: 'Solidity',
  sources: {
    'contracts/Kindora_NatSpec.sol': { content: kindoraNatSpec },
    'contracts/Kindora.sol': { content: kindora },
    'contracts/mocks/MockFactory.sol': { content: mockFactory },
    'contracts/mocks/MockRouter.sol': { content: mockRouter },
    'contracts/mocks/DummyERC20.sol': { content: dummyERC20 }
  },
  settings: {
    optimizer: {
      enabled: true,
      runs: 200
    },
    outputSelection: {
      '*': {
        '*': ['abi', 'evm.bytecode', 'evm.deployedBytecode']
      }
    }
  }
};

// Function to find imports
function findImports(importPath) {
  try {
    // Handle OpenZeppelin imports
    if (importPath.startsWith('@openzeppelin/')) {
      const ozPath = path.join(__dirname, 'node_modules', importPath);
      return {
        contents: fs.readFileSync(ozPath, 'utf8')
      };
    }
    
    // Handle local imports
    const localPath = path.join(contractsDir, importPath);
    if (fs.existsSync(localPath)) {
      return {
        contents: fs.readFileSync(localPath, 'utf8')
      };
    }
    
    return { error: 'File not found' };
  } catch (e) {
    return { error: e.message };
  }
}

console.log('Compiling contracts...');
const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));

// Check for errors
if (output.errors) {
  const errors = output.errors.filter(e => e.severity === 'error');
  if (errors.length > 0) {
    console.error('Compilation errors:');
    errors.forEach(e => console.error(e.formattedMessage));
    process.exit(1);
  }
  
  const warnings = output.errors.filter(e => e.severity === 'warning');
  if (warnings.length > 0) {
    console.warn('Compilation warnings:');
    warnings.forEach(w => console.warn(w.formattedMessage));
  }
}

// Create artifacts directory
const artifactsDir = path.join(__dirname, 'artifacts', 'contracts');
fs.mkdirSync(artifactsDir, { recursive: true });

// Save artifacts
if (output.contracts) {
  Object.keys(output.contracts).forEach(file => {
    Object.keys(output.contracts[file]).forEach(contractName => {
      const contract = output.contracts[file][contractName];
      const artifact = {
        _format: 'hh-sol-artifact-1',
        contractName: contractName,
        sourceName: file,
        abi: contract.abi,
        bytecode: '0x' + contract.evm.bytecode.object,
        deployedBytecode: '0x' + contract.evm.deployedBytecode.object,
        linkReferences: contract.evm.bytecode.linkReferences || {},
        deployedLinkReferences: contract.evm.deployedBytecode.linkReferences || {}
      };
      
      let outDir = artifactsDir;
      if (file.includes('mocks')) {
        outDir = path.join(__dirname, 'artifacts', 'contracts', 'mocks');
        fs.mkdirSync(outDir, { recursive: true });
      }
      
      const outFile = path.join(outDir, `${contractName}.json`);
      fs.writeFileSync(outFile, JSON.stringify(artifact, null, 2));
      console.log(`✓ Compiled ${contractName}`);
    });
  });
}

console.log('Compilation complete!');
