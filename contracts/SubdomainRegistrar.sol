pragma solidity ^0.4.17;

import "./ENS.sol";
import "./Resolver.sol";
import "./RegistrarInterface.sol";
import "./HashRegistrarSimplified.sol";

/**
 * @dev Implements an ENS registrar that sells subdomains on behalf of their owners.
 *
 * Users may register a subdomain by calling `register` with the name of the domain
 * they wish to register under, and the label hash of the subdomain they want to
 * register. They must also specify the new owner of the domain, and the referrer,
 * who is paid an optional finder's fee. The registrar then configures a simple
 * default resolver, which resolves `addr` lookups to the new owner, and sets
 * the `owner` account as the owner of the subdomain in ENS.
 *
 * New domains may be added by calling `configureDomain`, then transferring
 * ownership in the ENS registry to this contract. Ownership in the contract
 * may be transferred using `transfer`, and a domain may be unlisted for sale
 * using `unlistDomain`. There is (deliberately) no way to recover ownership
 * in ENS once the name is transferred to this registrar.
 *
 * Critically, this contract does not check two key properties of a listed domain:
 *
 * - Is the name UTS46 normalised?
 *
 * User applications MUST check these two elements for each domain before
 * offering them to users for registration.
 *
 * Applications should additionally check that the domains they are offering to
 * register are controlled by this registrar, since calls to `register` will
 * fail if this is not the case.
 */
contract SubdomainRegistrar is RegistrarInterface {

    // namehash('eth')
    bytes32 constant public TLD_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    ENS public ens;
    HashRegistrarSimplified public hashRegistrar;

    struct Domain {
        string name;
        address owner;
        uint price;
        uint referralFeePPM;
    }

    mapping (bytes32 => address) deedOwners;
    mapping (bytes32 => Domain) domains;

  modifier deed_owner_only(bytes32 label) {
    require(deedOwner(label) == msg.sender);
    _;
  }

  modifier new_registrar() {
    require(ens.owner(TLD_NODE) != address(hashRegistrar));
    _;
  }

    modifier owner_only(bytes32 label) {
        require(owner(label) == msg.sender);
        _;
    }

    function SubdomainRegistrar(ENS _ens) public {
        ens = _ens;
        hashRegistrar = HashRegistrarSimplified(ens.owner(TLD_NODE));
    }

    /**
     * @dev owner returns the address of the account that controls a domain.
     *      Initially this is the owner of the name in ENS. If the name has been
     *      transferred to this contract, then the internal mapping is consulted
     *      to determine who controls it.
     * @param label The label hash of the deed to check.
     * @return The address owning the deed.
     */
    function owner(bytes32 label) public view returns (address ret) {
        ret = ens.owner(keccak256(TLD_NODE, label));
        if (ret == address(this)) {
            ret = domains[label].owner;
        }
    }

    /**
     * @dev Transfers internal control of a name to a new account. Does not update
     *      ENS.
     * @param name The name to transfer.
     * @param newOwner The address of the new owner.
     */
    function transfer(string name, address newOwner) public owner_only(keccak256(name)) {
        var label = keccak256(name);
        OwnerChanged(keccak256(name), domains[label].owner, newOwner);
        domains[label].owner = newOwner;
    }

    /**
     * @dev Sets the resolver record for a name in ENS.
     * @param name The name to set the resolver for.
     * @param resolver The address of the resolver
     */
    function setResolver(string name, address resolver) public owner_only(keccak256(name)) {
        var label = keccak256(name);
        var node = keccak256(TLD_NODE, label);
        ens.setResolver(node, resolver);
    }

    /**
     * @dev Configures a domain for sale.
     * @param name The name to configure.
     * @param price The price in wei to charge for subdomain registrations
     * @param referralFeePPM The referral fee to offer, in parts per million
     */
    function configureDomain(string name, uint price, uint referralFeePPM) public owner_only(keccak256(name)) {
        var label = keccak256(name);
        var domain = domains[label];

        if (keccak256(domain.name) != label) {
            // New listing
            domain.name = name;
        }
        if (domain.owner != msg.sender) {
            domain.owner = msg.sender;
        }
        domain.price = price;
        domain.referralFeePPM = referralFeePPM;
        DomainConfigured(label);
    }

    /**
     * @dev Unlists a domain
     * May only be called by the owner.
     * @param name The name of the domain to unlist.
     */
    function unlistDomain(string name) public owner_only(keccak256(name)) {
        var label = keccak256(name);
        var domain = domains[label];
        DomainUnlisted(label);

        domain.name = '';
        domain.owner = owner(label);
        domain.price = 0;
        domain.referralFeePPM = 0;
    }

    /**
     * @dev Returns information about a subdomain.
     * @param label The label hash for the domain.
     * @param subdomain The label for the subdomain.
     * @return domain The name of the domain, or an empty string if the subdomain
     *                is unavailable.
     * @return price The price to register a subdomain, in wei.
     * @return rent The rent to retain a subdomain, in wei per second.
     * @return referralFeePPM The referral fee for the dapp, in ppm.
     */
    function query(bytes32 label, string subdomain) public view returns (string domain, uint price, uint rent, uint referralFeePPM) {
        var node = keccak256(TLD_NODE, label);
        var subnode = keccak256(node, keccak256(subdomain));

        if (ens.owner(subnode) != 0) {
            return ('', 0, 0, 0);
        }

        var data = domains[label];
        return (data.name, data.price, 0, data.referralFeePPM);
    }

    /**
     * @dev Registers a subdomain.
     * @param label The label hash of the domain to register a subdomain of.
     * @param subdomain The desired subdomain label.
     * @param subdomainOwner The account that should own the newly configured subdomain.
     * @param referrer The address of the account to receive the referral fee.
     */
    function register(bytes32 label, string subdomain, address subdomainOwner, address referrer, address resolver) public payable {
        var domainNode = keccak256(TLD_NODE, label);
        var subdomainLabel = keccak256(subdomain);

        // Subdomain must not be registered already.
        require(ens.owner(keccak256(domainNode, subdomainLabel)) == address(0));

        var domain = domains[label];

        // Domain must be available for registration
        require(keccak256(domain.name) == label);

        // User must have paid enough
        require(msg.value >= domain.price);

        // Send any extra back
        if (msg.value > domain.price) {
            msg.sender.transfer(msg.value - domain.price);
        }

        // Send any referral fee
        var total = domain.price;
        if (domain.referralFeePPM * domain.price > 0 && referrer != 0 && referrer != domain.owner) {
            uint256 referralFee = (domain.price * domain.referralFeePPM) / 1000000;
            referrer.transfer(referralFee);
            total -= referralFee;
        }

        // Send the registration fee
        if (total > 0) {
            domain.owner.transfer(total);
        }

        // Register the domain
        if (subdomainOwner == 0) {
            subdomainOwner = msg.sender;
        }
        doRegistration(domainNode, subdomainLabel, subdomainOwner, Resolver(resolver));

        NewRegistration(label, subdomain, subdomainOwner, referrer, domain.price);
    }

    function doRegistration(bytes32 node, bytes32 label, address subdomainOwner, Resolver resolver) internal {
        // Get the subdomain so we can configure it
        ens.setSubnodeOwner(node, label, this);

        var subnode = keccak256(node, label);
        // Set the subdomain's resolver
        ens.setResolver(subnode, resolver);

        // Set the address record on the resolver
        resolver.setAddr(subnode, subdomainOwner);

        // Pass ownership of the new subdomain to the registrant
        ens.setOwner(subnode, subdomainOwner);
    }

    function supportsInterface(bytes4 interfaceID) public pure returns (bool) {
        return (
            (interfaceID == 0x01ffc9a7) // supportsInterface(bytes4)
            || (interfaceID == 0xc1b15f5a) // RegistrarInterface
        );
    }

    function rentDue(bytes32 label, string subdomain) public view returns (uint timestamp) {
        return 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    }


  /**
   * @dev deedOwner returns the address of the account that ultimately owns a deed,
   *      if that deed has been transferred to the custodian. Initially
   *      this is the previousOwner of the deed. Afterwards, the owner may
   *      transfer control to anther account.
   * @param label The label hash of the deed to check.
   * @return The address owning the deed.
   */
  function deedOwner(bytes32 label) public view returns (address) {
    var (,deedAddress,,,) = hashRegistrar.entries(label);

    var deed = Deed(deedAddress);
    var deedOwner = deed.owner();
    if(deedOwner == address(this)) {
      // Use the previous owner if ownership hasn't been changed
      if(deedOwners[label] == 0) {
        return deed.previousOwner();
      }
      return deedOwners[label];
    }
    return 0;
  }

  /**
   * @dev Transfers control of a deed to a new account.
   * @param label The label hash of the deed to transfer.
   * @param newOwner The address of the new owner.
   */
  function transferDeed(bytes32 label, address newOwner) public deed_owner_only(label) {
    // Don't let users make the mistake of making the custodian itself the owner.
    require(newOwner != address(this));
    deedOwners[label] = newOwner;
  }

  /**
   * @dev Claims back the deed after a registrar upgrade.
   * @param label The label hash of the deed to transfer.
   */
  function claim(bytes32 label) public deed_owner_only(label) new_registrar {
    hashRegistrar.transfer(label, msg.sender);
  }

  /**
   * @dev Assigns ENS ownership if currently owned by the custodian.
   * Note this may only be called once - once not owned by the custodian,
   * this method will no longer function!
   * @param label The label hash of the ENS name to set.
   * @param owner The address of the new ENS owner.
   */
  function assign(bytes32 label, address owner) public deed_owner_only(label) {
    ens.setOwner(keccak256(hashRegistrar.rootNode(), label), owner);
  }

    function payRent(bytes32 label, string subdomain) public payable {
        revert();
    }
}
