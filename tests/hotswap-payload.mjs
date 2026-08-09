#!/usr/bin/env node

import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const script = process.env.HOTSWAP_SCRIPT ??
    path.resolve(here, '../scripts/looking-glass-hotswap.sh');
const uuid = 'test@example.com';
const token = 'behavior-token';

const generated = spawnSync(script, ['--one-line', '--token', token, uuid], {
    encoding: 'utf8',
});
assert.equal(generated.status, 0, generated.stderr);
const payload = generated.stdout.trim();

const ExtensionState = {
    ACTIVE: 1,
    INACTIVE: 2,
    ERROR: 3,
    ACTIVATING: 4,
    DEACTIVATING: 5,
};

async function executeScenario({
    initialState = ExtensionState.ACTIVE,
    oldDisableFails = false,
    replacementEnableFails = false,
    replacementDisableFails = false,
    orderInterference = false,
} = {}) {
    const calls = [];
    const oldState = {
        async enable() {
            calls.push('old.enable');
        },
        async disable() {
            calls.push('old.disable');
            if (oldDisableFails)
                throw new Error('old disable failed');
        },
    };

    class ReplacementState {
        constructor(metadata) {
            this.metadata = metadata;
            calls.push('replacement.construct');
        }

        async enable() {
            calls.push('replacement.enable');
            if (replacementEnableFails)
                throw new Error('replacement enable failed');
        }

        async disable() {
            calls.push('replacement.disable');
            if (replacementDisableFails)
                throw new Error('replacement disable failed');
        }
    }

    const extension = {
        uuid,
        state: initialState,
        stateObj: oldState,
        metadata: {uuid, name: 'Test'},
        path: `/tmp/${uuid}`,
        dir: {
            get_child(name) {
                assert.equal(name, 'extension.js');
                return {
                    query_exists() {
                        return true;
                    },
                    get_path() {
                        return `/tmp/${uuid}/extension.js`;
                    },
                    get_uri() {
                        return `file:///tmp/${uuid}/extension.js`;
                    },
                };
            },
        },
    };

    const manager = {
        _extensionOrder: ['before@example.com', uuid, 'after@example.com'],
        lookup(candidate) {
            calls.push(`lookup:${candidate}`);
            return candidate === uuid ? extension : null;
        },
        _changeExtensionState(target, state) {
            calls.push(`state:${state}`);
            target.state = state;
        },
        async _callExtensionDisable(candidate) {
            calls.push(`manager.disable:${candidate}`);
            if (extension.state !== ExtensionState.ACTIVE)
                return;
            extension.state = ExtensionState.DEACTIVATING;
            try {
                await extension.stateObj.disable();
            } catch {
                extension.state = ExtensionState.ERROR;
            }
            const index = this._extensionOrder.indexOf(candidate);
            if (index >= 0)
                this._extensionOrder.splice(index, 1);
            if (extension.state !== ExtensionState.ERROR)
                extension.state = ExtensionState.INACTIVE;
        },
        async _callExtensionEnable(candidate) {
            calls.push(`manager.enable:${candidate}`);
            if (extension.state !== ExtensionState.INACTIVE)
                return;
            extension.state = ExtensionState.ACTIVATING;
            try {
                await extension.stateObj.enable();
                extension.state = ExtensionState.ACTIVE;
                this._extensionOrder.push(candidate);
                if (orderInterference && extension.stateObj !== oldState)
                    this._extensionOrder.push('surprise@example.com');
            } catch {
                extension.state = ExtensionState.ERROR;
            }
        },
    };

    async function fakeImport(specifier) {
        calls.push(`import:${specifier}`);
        if (specifier.startsWith('resource:///'))
            return {ExtensionState};
        if (specifier.startsWith('file:///'))
            return {default: ReplacementState};
        throw new Error(`unexpected import: ${specifier}`);
    }

    const logged = [];
    const fakeConsole = {
        log(message) {
            logged.push(['log', message]);
        },
        error(message) {
            logged.push(['error', message]);
        },
    };

    const rewritten = payload.replaceAll('await import(', 'await __import(');
    const lines = rewritten.split(';');
    lines.push(`return ${lines.pop()}`);
    const AsyncFunction = async function () {}.constructor;
    const evaluate = new AsyncFunction('Main', '__import', 'console', lines.join(';'));
    const serialized = await evaluate({extensionManager: manager}, fakeImport, fakeConsole);

    return {
        proof: JSON.parse(serialized),
        calls,
        extension,
        manager,
        oldState,
        logged,
    };
}

{
    const result = await executeScenario();
    assert.equal(result.proof.ok, true);
    assert.equal(result.proof.phase, 'complete');
    assert.equal(result.proof.stateObjectReplaced, true);
    assert.equal(result.proof.reenableMovedTarget, true);
    assert.equal(result.proof.orderBookkeepingRestored, true);
    assert.deepEqual(result.manager._extensionOrder, [
        'before@example.com',
        uuid,
        'after@example.com',
    ]);
    assert.equal(result.extension.state, ExtensionState.ACTIVE);
    assert.notEqual(result.extension.stateObj, result.oldState);
    assert.match(result.logged.at(-1)[1], new RegExp(`gnome-wayland-reload:${token}`));
    console.log('ok - successful replacement restores extension-order bookkeeping');
}

{
    const result = await executeScenario({initialState: ExtensionState.INACTIVE});
    assert.equal(result.proof.ok, false);
    assert.equal(result.proof.phase, 'preflight');
    assert.equal(result.proof.rollback.needed, false);
    assert.equal(result.proof.rollback.ok, true);
    assert.equal(result.extension.stateObj, result.oldState);
    assert.equal(result.calls.some(call => call.startsWith('manager.disable')), false);
    console.log('ok - non-ACTIVE target is refused before mutation');
}

{
    const result = await executeScenario({replacementEnableFails: true});
    assert.equal(result.proof.ok, false);
    assert.equal(result.proof.phase, 'enable-replacement');
    assert.equal(result.proof.rollback.needed, true);
    assert.equal(result.proof.rollback.attempted, true);
    assert.equal(result.proof.rollback.ok, true);
    assert.equal(result.proof.rollback.replacementCleanupOk, true);
    assert.equal(result.proof.rollback.stateObjectRestored, true);
    assert.equal(result.proof.rollback.activeStateRestored, true);
    assert.equal(result.proof.rollback.orderBookkeepingRestored, true);
    assert.equal(result.extension.stateObj, result.oldState);
    assert.equal(result.extension.state, ExtensionState.ACTIVE);
    assert.deepEqual(result.manager._extensionOrder, [
        'before@example.com',
        uuid,
        'after@example.com',
    ]);
    console.log('ok - replacement enable failure proves complete rollback');
}

{
    const result = await executeScenario({
        replacementEnableFails: true,
        replacementDisableFails: true,
    });
    assert.equal(result.proof.ok, false);
    assert.equal(result.proof.phase, 'enable-replacement');
    assert.equal(result.proof.rollback.replacementCleanupAttempted, true);
    assert.equal(result.proof.rollback.replacementCleanupOk, false);
    assert.equal(result.proof.rollback.stateObjectRestored, true);
    assert.equal(result.proof.rollback.activeStateRestored, true);
    assert.equal(result.proof.rollback.ok, false);
    assert.match(result.proof.rollback.error, /replacement cleanup/);
    console.log('ok - replacement cleanup failure can never be called a complete rollback');
}

{
    const result = await executeScenario({orderInterference: true});
    assert.equal(result.proof.ok, false);
    assert.equal(result.proof.phase, 'restore-order');
    assert.equal(result.proof.rollback.needed, true);
    assert.equal(result.proof.rollback.ok, false);
    assert.equal(result.proof.stateObjectReplaced, false);
    assert.equal(result.extension.stateObj, result.oldState);
    assert.equal(result.extension.state, ExtensionState.ACTIVE);
    console.log('ok - bookkeeping mismatch fails the transaction and attempts rollback');
}

{
    const result = await executeScenario({oldDisableFails: true});
    assert.equal(result.proof.ok, false);
    assert.equal(result.proof.phase, 'disable-current');
    assert.equal(result.proof.rollback.needed, true);
    assert.equal(result.proof.rollback.attempted, true);
    assert.equal(result.proof.rollback.ok, false);
    assert.equal(result.proof.rollback.stateObjectRestored, true);
    assert.equal(result.proof.rollback.activeStateRestored, false);
    assert.match(result.proof.rollback.error, /manual recovery required/);
    assert.equal(result.extension.stateObj, result.oldState);
    assert.equal(result.extension.state, ExtensionState.ERROR);
    assert.deepEqual(result.manager._extensionOrder, [
        'before@example.com',
        uuid,
        'after@example.com',
    ]);
    console.log('ok - unsafe current-disable failure is explicit and never called restored');
}
