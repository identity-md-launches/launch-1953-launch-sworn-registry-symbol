// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "src/Registry.sol";
import {Renderer} from "src/Renderer.sol";
import {Composer} from "src/Composer.sol";
import {FloorProbe} from "../Floor.t.sol";
import {MockCurator, MockIDMD, MockIMD, MockIntake} from "../mocks/Mocks.sol";

/// @dev Models only the V1 selector boundary in the brief. There is deliberately no
/// previewBridge or fallback. This is not a copy of the live executor's implementation.
contract SepoliaLegacyExecutor {
    uint256 public calls;

    function bridgeToBaseBurnReceiver(uint256, address) external payable {
        calls++;
    }
}

/// @dev Hermetic fixture: real launch arguments, mock dependencies at those addresses.
/// The factory creates only Renderer, Composer and Registry, in one call. No fork or keys.
abstract contract SepoliaFixture is Test {
    address internal constant CURATOR = 0x0919ba50b206C3F31D516De818b1fBc7dA21653D;
    address internal constant IDMD = 0x2C3013c90a1Bb65573aae9a7C64fafB82697E4e4;
    address internal constant IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address internal constant EXECUTOR = 0x097A19e0f021BBA5072701132625ad2401043A2E;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant START = 1_791_700_000;
    uint256 internal constant PRICE = 0.5 ether;

    MockCurator internal curator;
    MockIDMD internal idmd;
    MockIMD internal imd;
    MockIntake internal intake;
    SepoliaLegacyExecutor internal executor;
    Registry internal registry;
    FloorProbe internal factory;
    address[] internal applications;

    function setUp() public virtual {
        vm.chainId(SEPOLIA);
        vm.roll(11_926_289);
        vm.warp(START);
        deployCodeTo("Mocks.sol:MockCurator", CURATOR);
        deployCodeTo("Mocks.sol:MockIDMD", IDMD);
        deployCodeTo("Mocks.sol:MockIMD", IMD);
        deployCodeTo("Mocks.sol:MockIntake", abi.encode(IMD), INTAKE);
        deployCodeTo("SepoliaFixture.sol:SepoliaLegacyExecutor", EXECUTOR);
        curator = MockCurator(CURATOR);
        idmd = MockIDMD(IDMD);
        imd = MockIMD(IMD);
        intake = MockIntake(INTAKE);
        executor = SepoliaLegacyExecutor(EXECUTOR);
        factory = new FloorProbe();
        (bytes[] memory codes, bytes32[] memory salts,) = _launchCodes(bytes32("launch"), _dependencies());
        applications = factory.deployAll(codes, salts);
        registry = Registry(applications[2]);
    }

    function _dependencies() internal pure returns (address[6] memory) {
        return [CURATOR, IDMD, IMD, INTAKE, ATTESTER, EXECUTOR];
    }

    function _launchCodes(bytes32 tag, address[6] memory deps)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory salts, address[] memory predicted)
    {
        codes = new bytes[](3);
        salts = new bytes32[](3);
        predicted = new address[](3);
        for (uint256 i; i < 3; ++i) {
            salts[i] = keccak256(abi.encode(tag, i));
        }
        codes[0] = vm.getCode("Renderer.sol:Renderer");
        codes[1] = vm.getCode("Composer.sol:Composer");
        predicted[0] = _predict(salts[0], codes[0]);
        predicted[1] = _predict(salts[1], codes[1]);
        codes[2] = bytes.concat(
            vm.getCode("Registry.sol:Registry"),
            abi.encode(deps[0], deps[1], deps[2], deps[3], deps[4], predicted[0], predicted[1], deps[5])
        );
        predicted[2] = _predict(salts[2], codes[2]);
    }

    function _predict(bytes32 salt, bytes memory code) internal view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
            );
    }

    function _fund(address who, uint256 amount) internal {
        imd.mint(who, amount);
        vm.prank(who);
        imd.approve(address(registry), type(uint256).max);
    }

    function _member(address who, uint256 tokenId) internal {
        curator.set(who, 1, true, 1, 1 ether, 1000);
        idmd.setOwner(tokenId, who);
    }

    function _one(uint16 traitId) internal pure returns (uint16[] memory ids) {
        ids = new uint16[](1);
        ids[0] = traitId;
    }

    function _claim(address who, bool throughIdmd, uint16 traitId, uint256 value) internal {
        vm.prank(who);
        if (throughIdmd) registry.upgradeSponsored{value: value}(7, _one(traitId));
        else registry.claimSponsored{value: value}(traitId);
    }

    function _ask(address who, uint16 traitId) internal returns (bytes32) {
        uint256 price = intake.price();
        _fund(who, price);
        vm.prank(who);
        registry.upgrade(_one(traitId), price);
        return registry.pendingOf(who, traitId);
    }
}
