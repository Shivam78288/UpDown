const Updown = artifacts.require("Updown.sol");

module.exports = function (deployer) {
  deployer.deploy(Updown);
};
