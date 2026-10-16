// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";

/// @notice The launch factory supplies creation code, then constructor arguments, to CREATE2.
contract FloorProbe {
    /// @dev Keep all CREATE2 operations in one transaction, matching the launch factory.
    function deployAll(bytes[] memory initCodes, bytes32[] memory salts) external returns (address[] memory deployed) {
        require(initCodes.length == salts.length, "length mismatch");
        deployed = new address[](initCodes.length);
        for (uint256 i; i < initCodes.length; ++i) {
            deployed[i] = _deploy(initCodes[i], salts[i]);
        }
    }

    function _deploy(bytes memory initCode, bytes32 salt) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}

/// @notice Both launch parameter sets must deploy on an empty dependency floor without an admin.
contract FloorTest is Test {
    function test_mainnetEmptyChainFloor() public {
        vm.chainId(1);
        _floor(
            0xcB0b0531e86A9aC36Fa865cA8e3dbccF047FDA91,
            0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D,
            0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7,
            0xe29386719C155B6847aD5a4E97C6674f10ffc750
        );
    }

    function test_sepoliaEmptyChainFloor() public {
        vm.chainId(11155111);
        _floor(
            0x0919ba50b206C3F31D516De818b1fBc7dA21653D,
            0x2C3013c90a1Bb65573aae9a7C64fafB82697E4e4,
            0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A,
            0x097A19e0f021BBA5072701132625ad2401043A2E
        );
    }

    function _floor(address curator, address idmd, address imd, address executor) internal {
        FloorProbe probe = new FloorProbe();
        bytes memory rendererCode = vm.getCode("Renderer.sol:Renderer");
        bytes memory composerCode = vm.getCode("Composer.sol:Composer");
        address[8] memory args = [
            curator,
            idmd,
            imd,
            0xa43e6F75ee006411F79Ac1C84120606C2330DE82,
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982,
            _predict(address(probe), bytes32("Renderer"), rendererCode),
            _predict(address(probe), bytes32("Composer"), composerCode),
            executor
        ];
        for (uint256 i; i < 5; ++i) {
            assertEq(args[i].code.length, 0, "dependency floor must be empty");
        }
        assertEq(executor.code.length, 0, "executor floor must be empty");
        bytes memory registryCode = bytes.concat(
            vm.getCode("Registry.sol:Registry"),
            abi.encode(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7])
        );
        address predictedRegistry = _predict(address(probe), bytes32("Registry"), registryCode);
        bytes[] memory codes = new bytes[](3);
        codes[0] = rendererCode;
        codes[1] = composerCode;
        codes[2] = registryCode;
        bytes32[] memory salts = new bytes32[](3);
        salts[0] = bytes32("Renderer");
        salts[1] = bytes32("Composer");
        salts[2] = bytes32("Registry");
        uint64 factoryNonce = vm.getNonce(address(probe));
        address[] memory applications = probe.deployAll(codes, salts);
        assertEq(applications.length, 3);
        assertEq(vm.getNonce(address(probe)), factoryNonce + 3, "factory creates exactly three applications");
        for (uint256 i; i < applications.length; ++i) {
            assertLe(codes[i].length, 49_152, "init code exceeds EIP-3860");
            assertEq(vm.getNonce(applications[i]), 1, "application constructor created an extra contract");
            assertEq(applications[i].balance, 0, "deployment must send no ETH");
        }
        assertEq(applications[0], args[5]);
        assertEq(applications[1], args[6]);
        address deployed = applications[2];
        assertEq(deployed, predictedRegistry);
        _runtime(args[5]);
        _runtime(args[6]);
        _runtime(deployed);
        Registry registry = Registry(deployed);
        assertEq(address(registry.curator()), args[0]);
        assertEq(address(registry.idmd()), args[1]);
        assertEq(address(registry.imd()), args[2]);
        assertEq(address(registry.intake()), args[3]);
        assertEq(registry.attester(), args[4]);
        assertEq(address(registry.renderer()), args[5]);
        assertEq(address(registry.composer()), args[6]);
        assertEq(address(registry.burnExecutor()), args[7]);
        assertEq(registry.name(), "Sworn");
        assertEq(registry.symbol(), "SWORN");
        assertEq(registry.nextSpecId(), 10001);
    }

    function _predict(address factory, bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, keccak256(initCode))))));
    }

    function _runtime(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0, "deployment has no runtime");
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff, "forbidden runtime opcode");
        }
        (bool ownerExists, bytes memory ownerData) = target.staticcall(abi.encodeWithSignature("owner()"));
        (bool adminExists, bytes memory adminData) = target.staticcall(abi.encodeWithSignature("admin()"));
        assertFalse(ownerExists, "owner() exists");
        assertFalse(adminExists, "admin() exists");
        assertEq(ownerData.length, 0);
        assertEq(adminData.length, 0);
    }
}
