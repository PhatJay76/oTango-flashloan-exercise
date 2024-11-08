module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();
    await deploy("FlashLoan", {
      contract: "FlashLoan",
      from: deployer,
      log: true,
      args: [],
      skipIfAlreadyDeployed: true
    });
  };
  module.exports.tags = ["FlashLoan"];
  