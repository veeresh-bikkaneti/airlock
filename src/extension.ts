import * as vscode from 'vscode';
import * as http from 'http';
import * as fs from 'fs';
import * as path from 'path';

let terminal: vscode.Terminal | undefined;
let statusBar: vscode.StatusBarItem;
let pollTimer: NodeJS.Timeout | undefined;

function getScriptsPath(): string {
    const configured = vscode.workspace.getConfiguration('airlock').get<string>('deployedScriptsPath') || '';
    return configured.replace(/\$\{env:([^}]+)\}/g, (_, name) => process.env[name] || '');
}

function getModelsConfigPath(): string {
    const explicit = vscode.workspace.getConfiguration('airlock').get<string>('modelsConfigPath');
    if (explicit) { return explicit; }
    return path.join(getScriptsPath(), '..', 'config', 'models.json');
}

function getActivePortPath(): string {
    return path.join(getScriptsPath(), '..', '.active-port.json');
}

function getTerminal(): vscode.Terminal {
    if (!terminal || terminal.exitStatus !== undefined) {
        terminal = vscode.window.createTerminal('Airlock');
    }
    return terminal;
}

function runHelper(verb: string) {
    const scriptsPath = getScriptsPath();
    const helpers = path.join(scriptsPath, 'profile-helpers.ps1');
    const term = getTerminal();
    term.show();
    term.sendText(`. "${helpers}"; ${verb}`);
}

function checkHealth(port: number): Promise<boolean> {
    return new Promise((resolve) => {
        const req = http.get({ host: '127.0.0.1', port, path: '/api/tags', timeout: 2000 }, (res) => {
            resolve(res.statusCode === 200);
            res.resume();
        });
        req.on('error', () => resolve(false));
        req.on('timeout', () => { req.destroy(); resolve(false); });
    });
}

async function refreshStatusBar() {
    let port = vscode.workspace.getConfiguration('airlock').get<number>('healthPort') || 12345;
    let model: string | undefined;
    const activePortPath = getActivePortPath();
    if (fs.existsSync(activePortPath)) {
        try {
            const state = JSON.parse(fs.readFileSync(activePortPath, 'utf8'));
            if (state.port) { port = state.port; }
            model = state.model;
        } catch {
            // fall back to configured healthPort
        }
    }
    const healthy = await checkHealth(port);
    const label = model ? `${model} (:${port})` : `:${port}`;
    statusBar.text = healthy ? `$(check) Airlock: ${label}` : `$(circle-slash) Airlock: stopped`;
    statusBar.color = healthy ? undefined : new vscode.ThemeColor('errorForeground');
}

function startPolling() {
    if (pollTimer) { clearInterval(pollTimer); }
    const seconds = vscode.workspace.getConfiguration('airlock').get<number>('healthPollSeconds') ?? 15;
    refreshStatusBar();
    if (seconds > 0) {
        pollTimer = setInterval(refreshStatusBar, seconds * 1000);
    }
}

async function selectModel() {
    const configPath = getModelsConfigPath();
    if (!fs.existsSync(configPath)) {
        vscode.window.showErrorMessage(`models.json not found at ${configPath}. Set airlock.modelsConfigPath.`);
        return;
    }
    let config: any;
    try {
        config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    } catch (e) {
        vscode.window.showErrorMessage(`models.json at ${configPath} is not valid JSON.`);
        return;
    }
    const names: string[] = Object.keys(config.localModels || {});
    const picked = await vscode.window.showQuickPick(names.map(name => ({
        label: name,
        description: config.localModels[name].role,
        detail: `${config.localModels[name].size} · ${config.localModels[name].parameters} params`
    })));
    if (picked) {
        runHelper(`ai-start -StrictPort -Model "${picked.label}"`);
    }
}

async function switchModel() {
    const configPath = getModelsConfigPath();
    if (!fs.existsSync(configPath)) {
        vscode.window.showErrorMessage(`models.json not found at ${configPath}. Set airlock.modelsConfigPath.`);
        return;
    }
    let config: any;
    try {
        config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    } catch (e) {
        vscode.window.showErrorMessage(`models.json at ${configPath} is not valid JSON.`);
        return;
    }
    const names: string[] = Object.keys(config.localModels || {});
    const picked = await vscode.window.showQuickPick(names.map(name => ({
        label: name,
        description: config.localModels[name].role,
        detail: `${config.localModels[name].size} · ${config.localModels[name].parameters} params`
    })));
    if (picked) {
        runHelper(`ai-switch "${picked.label}"`);
        setTimeout(refreshStatusBar, 2000);
    }
}

export function activate(context: vscode.ExtensionContext) {
    statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    statusBar.show();
    context.subscriptions.push(statusBar);

    context.subscriptions.push(
        vscode.commands.registerCommand('airlock.start', () => { runHelper('ai-start -StrictPort'); setTimeout(refreshStatusBar, 5000); }),
        vscode.commands.registerCommand('airlock.stop', () => { runHelper('ai-stop'); setTimeout(refreshStatusBar, 2000); }),
        vscode.commands.registerCommand('airlock.health', () => { runHelper('ai-health'); refreshStatusBar(); }),
        vscode.commands.registerCommand('airlock.code', () => runHelper('ai-code')),
        vscode.commands.registerCommand('airlock.selectModel', selectModel),
        vscode.commands.registerCommand('airlock.switchModel', switchModel),
        vscode.workspace.onDidChangeConfiguration(e => {
            if (e.affectsConfiguration('airlock')) { startPolling(); }
        })
    );
    statusBar.command = 'airlock.health';

    startPolling();
}

export function deactivate() {
    if (pollTimer) { clearInterval(pollTimer); }
}
