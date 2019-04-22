var DummyHashRegistrar = artifacts.require("DummyHashRegistrar");
var TestResolver = artifacts.require("TestResolver");
var ENS = artifacts.require("@ensdomains/ens/contracts/ENSRegistry.sol");
var SubdomainRegistrar = artifacts.require("SubdomainRegistrar");

var namehash = require('eth-ens-namehash');
var sha3 = require('js-sha3').keccak_256;
var Promise = require('bluebird');

var domainnames = require('../app/js/domains.json');

module.exports = function (deployer, network, accounts) {
    return deployer.then(async () => {
        if (network == "test") {

            await deployer.deploy(ENS);

            const ens = await ENS.deployed();
            await deployer.deploy(DummyHashRegistrar, ens.address);
            await deployer.deploy(TestResolver, ens.address);

            await ens.setSubnodeOwner('0x0', '0x' + sha3('eth'), accounts[0]);
            await ens.setSubnodeOwner(namehash.hash('eth'), '0x' + sha3('resolver'), accounts[0]);

            const resolver = await TestResolver.deployed();
            await ens.setResolver(namehash.hash('resolver.eth'), resolver.address);

            const dhr = await DummyHashRegistrar.deployed();
            await ens.setSubnodeOwner('0x0', '0x' + sha3('eth'), dhr.address);

            await deployer.deploy(SubdomainRegistrar, ens.address);

            const registrar = await SubdomainRegistrar.deployed();

            return Promise.map(domainnames, async function(domain) {
                if(domain.registrar !== undefined) return;
                await dhr.setSubnodeOwner('0x' + sha3(domain.name), accounts[0]);
                await dhr.transfer('0x' + sha3(domain.name), registrar.address);
                await registrar.configureDomain(domain.name, 1e16, 100000);
            });
        } else {
            const ens = ENS.deployed();
            await deployer.deploy(SubdomainRegistrar, ens.address);
        }
    });
};
