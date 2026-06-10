// DeviceIdle Manager WebUI - Fixed version
// 修复了: 导入兼容性、exec超时、阻塞初始化、错误处理

// ========== 1. 安全导入 KernelSU API ==========
let ksuExec = null;
let ksuToast = null;
let _cbCounter = 0;

try {
    const api = await import('ksuapi');
    if (typeof api.exec === 'function') {
        ksuExec = api.exec.bind(api);
        ksuToast = typeof api.toast === 'function' ? api.toast.bind(api) : null;
    }
} catch (e) {
    console.warn('[KSU] ksuapi import failed:', e);
}

try {
    if (!ksuExec && typeof window !== 'undefined' && window.ksuapi && typeof window.ksuapi.exec === 'function') {
        ksuExec = window.ksuapi.exec.bind(window.ksuapi);
        ksuToast = typeof window.ksuapi.toast === 'function' ? window.ksuapi.toast.bind(window.ksuapi) : null;
    }
    if (!ksuExec && typeof window !== 'undefined' && window.kernelsu && typeof window.kernelsu.exec === 'function') {
        ksuExec = window.kernelsu.exec.bind(window.kernelsu);
        ksuToast = typeof window.kernelsu.toast === 'function' ? window.kernelsu.toast.bind(window.kernelsu) : null;
    }
    if (!ksuExec && typeof window !== 'undefined' && window.ksu && typeof window.ksu.exec === 'function') {
        ksuExec = function(cmd) {
            return new Promise(function(resolve) {
                const callbackName = '__dim_exec_' + (_cbCounter++) + '_' + Date.now();
                const timer = setTimeout(function() {
                    delete window[callbackName];
                    resolve({ errno: -1, stdout: '', stderr: 'exec timeout' });
                }, 15000);
                window[callbackName] = function(errno, stdout, stderr) {
                    clearTimeout(timer);
                    delete window[callbackName];
                    resolve({ errno, stdout: stdout || '', stderr: stderr || '' });
                };
                try {
                    window.ksu.exec(cmd, '{}', callbackName);
                } catch (e1) {
                    try {
                        window.ksu.exec(cmd, callbackName);
                    } catch (e2) {
                        clearTimeout(timer);
                        delete window[callbackName];
                        resolve({ errno: -1, stdout: '', stderr: String(e2) });
                    }
                }
            });
        };
    }
} catch (e) {
    console.warn('[KSU] window API not available:', e);
}

// 如果上面的方式不行，尝试通过 ES module import
if (!ksuExec) {
    try {
        const ksu = await import('kernelsu');
        ksuExec = ksu.exec;
        ksuToast = ksu.toast;
    } catch (e) {
        console.warn('[KSU] ES module import failed:', e);
    }
}

// 如果仍然没有 exec，尝试最后一个备选
if (!ksuExec) {
    try {
        const ksu = await import('/kernelsu');
        ksuExec = ksu.exec;
        ksuToast = ksu.toast;
    } catch (e) {
        console.warn('[KSU] Absolute path import failed:', e);
    }
}

// 兜底: 如果 exec 完全不可用，显示致命错误
if (!ksuExec) {
    console.error('[KSU] CRITICAL: exec API not available!');
    document.addEventListener('DOMContentLoaded', () => {
        const list = document.getElementById('app-list');
        if (list) {
            list.innerHTML = `
                <div class="empty-state" style="display:flex">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>
                    </svg>
                    <p>KernelSU API 不可用</p>
                    <p class="hint">请确保使用 KernelSU v0.7.0+ 并启用 WebUI 支持</p>
                </div>
            `;
        }
    });
    // 停止执行
    throw new Error('KernelSU exec API not available');
}

// ========== 2. 常量与状态 ==========
const MODULE_DIR = '/data/adb/modules/ksu_deviceidle_manager';
const TARGET_FILE = '/data/system/deviceidle.xml';
const ACTIVE_FILE = `${MODULE_DIR}/active/deviceidle.xml`;
const BACKUP_FILE = `${MODULE_DIR}/backup/original_deviceidle.xml`;
const MANAGER = `${MODULE_DIR}/manager.sh`;

let currentPackages = [];
let originalPackages = [];
let isProcessing = false;
let confirmCallback = null;

// ========== 3. 核心工具函数 ==========

// exec 带超时保护
function execWithTimeout(cmd, timeoutMs = 5000) {
    return Promise.race([
        ksuExec(cmd),
        new Promise((_, reject) => {
            setTimeout(() => reject(new Error('EXEC_TIMEOUT')), timeoutMs);
        })
    ]);
}

// 安全执行命令
async function runCmd(cmd, timeoutMs = 5000) {
    try {
        const result = await execWithTimeout(cmd, timeoutMs);
        // 处理可能的 undefined stdout/stderr
        const stdout = result && result.stdout ? result.stdout : '';
        const stderr = result && result.stderr ? result.stderr : '';
        const errno = result && result.errno !== undefined ? result.errno : -1;
        
        return {
            success: (errno === 0 || errno === '0'),
            stdout: stdout,
            stderr: stderr,
            code: errno
        };
    } catch (e) {
        if (e.message === 'EXEC_TIMEOUT') {
            console.warn('[KSU] Command timeout:', cmd);
        } else {
            console.error('[KSU] Command error:', cmd, e);
        }
        return {
            success: false,
            stdout: '',
            stderr: e.message || 'Error',
            code: -1
        };
    }
}

function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function parsePackageList(text) {
    return [...new Set((text || '')
        .split(/\r?\n/)
        .map(line => line.trim().toLowerCase())
        .filter(pkg => /^[a-z0-9_]+(\.[a-z0-9_]+)+$/.test(pkg)))]
        .sort();
}

function escapeHtml(str) {
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

// 显示 Toast
function showToast(message, type = 'success') {
    // 优先尝试 KernelSU 原生 toast
    if (ksuToast) {
        try {
            ksuToast(message);
        } catch (e) {
            console.warn('[KSU] toast failed:', e);
        }
    }
    
    // 自定义 DOM toast
    const toastEl = document.getElementById('toast');
    const iconEl = document.getElementById('toast-icon');
    const msgEl = document.getElementById('toast-message');
    
    if (toastEl && msgEl && iconEl) {
        msgEl.textContent = message;
        iconEl.textContent = type === 'success' ? '✓' : type === 'error' ? '✗' : 'ℹ';
        toastEl.classList.add('show');
        setTimeout(() => {
            toastEl.classList.remove('show');
        }, 2500);
    }
}

// ========== 4. XML 解析与生成 ==========

async function parseDeviceIdleXml(path) {
    try {
        const result = await runCmd(`cat "${path}" 2>/dev/null`, 3000);
        
        if (!result.success || !result.stdout || !result.stdout.trim()) {
            console.log('[DeviceIdle] No content or file not found:', path);
            return [];
        }
        
        const content = result.stdout;
        const packages = new Set();
        
        const patterns = [
            /packageName="([^"]+)"/g,
            /package="([^"]+)"/g,
            /n="([^"]+)"/g,
        ];
        
        for (const pattern of patterns) {
            let match;
            while ((match = pattern.exec(content)) !== null) {
                const pkg = match[1].trim().toLowerCase();
                if (pkg && pkg.includes('.') && pkg.length > 3) {
                    packages.add(pkg);
                }
            }
        }
        
        const packagesList = Array.from(packages).sort();
        console.log('[DeviceIdle] Parsed packages from', path, ':', packagesList.length);
        return packagesList;
    } catch (e) {
        console.error('[DeviceIdle] parseDeviceIdleXml error:', e);
        return [];
    }
}

async function generateDeviceIdleXml(packages) {
    const lines = packages.map(pkg => `    <wl n="${pkg}" />`);
    return `<?xml version="1.0" encoding="utf-8"?>\n<config>\n${lines.join('\n')}\n</config>`;
}

// 使用临时文件写入（更安全）
async function writeXmlFile(path, content) {
    try {
        const tmpPath = `${path}.tmp`;
        
        // 清空临时文件
        const clearResult = await runCmd(`true > "${tmpPath}"`, 3000);
        if (!clearResult.success) {
            console.error('[DeviceIdle] Failed to clear tmp file');
        }
        
        // 分段写入（每行一个命令）
        const lines = content.split('\n');
        for (const line of lines) {
            const escaped = line.replace(/'/g, "'\\''").replace(/\\/g, '\\\\');
            const writeResult = await runCmd(`echo '${escaped}' >> "${tmpPath}"`, 3000);
            if (!writeResult.success) {
                console.error('[DeviceIdle] Write line failed:', writeResult.stderr);
            }
        }
        
        // 移动临时文件到目标
        const mvResult = await runCmd(`mv "${tmpPath}" "${path}"`, 3000);
        return mvResult.success;
    } catch (e) {
        console.error('[DeviceIdle] writeXmlFile error:', e);
        return false;
    }
}

// ========== 5. 核心逻辑 ==========

async function loadPackages() {
    console.log('[DeviceIdle] Loading packages...');
    
    try {
        const current = await runCmd(`sh "${MANAGER}" list`, 5000);
        const original = await runCmd(`sh "${MANAGER}" original-list`, 5000);
        currentPackages = current.success ? parsePackageList(current.stdout) : await parseDeviceIdleXml(ACTIVE_FILE);
        originalPackages = original.success ? parsePackageList(original.stdout) : await parseDeviceIdleXml(BACKUP_FILE);
        console.log('[DeviceIdle] Loaded:', currentPackages.length, 'current,', originalPackages.length, 'original');
    } catch (e) {
        console.error('[DeviceIdle] loadPackages error:', e);
        currentPackages = [];
        originalPackages = [];
    }
    
    updateAppList();
    updateStats();
}

async function savePackages() {
    if (isProcessing) return false;
    isProcessing = true;
    
    console.log('[DeviceIdle] Saving packages...');
    
    try {
        const csv = currentPackages
            .filter(pkg => /^[a-z0-9_]+(\.[a-z0-9_]+)+$/.test(pkg))
            .join(',');
        const syncResult = await runCmd(`sh "${MANAGER}" set-list ${shellQuote(csv)}`, 10000);
        
        isProcessing = false;
        
        if (syncResult.success) {
            showToast('配置已保存并同步');
            updateStats();
            return true;
        } else {
            console.error('[DeviceIdle] Sync failed:', syncResult.stderr);
            showToast('同步到系统失败: ' + syncResult.stderr, 'error');
            return false;
        }
    } catch (e) {
        console.error('[DeviceIdle] savePackages error:', e);
        showToast('保存失败: ' + e.message, 'error');
        isProcessing = false;
        return false;
    }
}

async function addPackage(pkg) {
    pkg = pkg.trim().toLowerCase();
    if (!pkg) {
        showToast('请输入包名', 'error');
        return false;
    }
    if (!pkg.includes('.')) {
        showToast('包名格式不正确', 'error');
        return false;
    }
    if (currentPackages.includes(pkg)) {
        showToast('该应用已在白名单中', 'error');
        return false;
    }
    
    currentPackages.push(pkg);
    currentPackages.sort();
    
    await savePackages();
    updateAppList(document.getElementById('search-input')?.value || '');
    return true;
}

async function addPackages(packages) {
    let added = 0;
    for (let pkg of packages) {
        pkg = pkg.trim().toLowerCase();
        if (pkg && pkg.includes('.') && !currentPackages.includes(pkg)) {
            currentPackages.push(pkg);
            added++;
        }
    }
    
    if (added === 0) {
        showToast('没有新的应用被添加', 'error');
        return false;
    }
    
    currentPackages.sort();
    await savePackages();
    updateAppList(document.getElementById('search-input')?.value || '');
    showToast(`已添加 ${added} 个应用`);
    return true;
}

window.removePackage = async function(pkg) {
    if (isProcessing) return;
    
    const idx = currentPackages.indexOf(pkg);
    if (idx === -1) return;
    
    currentPackages.splice(idx, 1);
    await savePackages();
    updateAppList(document.getElementById('search-input')?.value || '');
    showToast('已移除: ' + pkg);
};

async function importPackages(text, replace = false) {
    const lines = text.split('\n');
    const newPackages = [];
    
    for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        
        const match = trimmed.match(/([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*)/i);
        if (match) {
            newPackages.push(match[1].toLowerCase());
        }
    }
    
    if (newPackages.length === 0) {
        showToast('未找到有效的包名', 'error');
        return false;
    }
    
    if (replace) {
        currentPackages = [...new Set(newPackages)].sort();
    } else {
        currentPackages = [...new Set([...currentPackages, ...newPackages])].sort();
    }
    
    await savePackages();
    updateAppList(document.getElementById('search-input')?.value || '');
    showToast(`已导入 ${newPackages.length} 个应用${replace ? '（已覆盖）' : ''}`);
    return true;
}

function exportPackages() {
    return currentPackages.join('\n');
}

async function restoreOriginal() {
    if (!originalPackages.length) {
        showToast('原始备份不存在', 'error');
        return false;
    }
    
    currentPackages = [...originalPackages];
    await savePackages();
    updateAppList(document.getElementById('search-input')?.value || '');
    showToast('已恢复原始配置');
    return true;
}

// ========== 6. UI 更新 ==========

function updateAppList(filter = '') {
    const listEl = document.getElementById('app-list');
    const emptyEl = document.getElementById('empty-state');
    
    if (!listEl || !emptyEl) return;
    
    let filtered = currentPackages;
    if (filter.trim()) {
        const lower = filter.toLowerCase();
        filtered = currentPackages.filter(pkg => pkg.toLowerCase().includes(lower));
    }
    
    if (filtered.length === 0) {
        listEl.innerHTML = '';
        emptyEl.style.display = 'flex';
        return;
    }
    
    emptyEl.style.display = 'none';
    
    listEl.innerHTML = filtered.map(pkg => `
        <div class="app-item" data-package="${pkg}">
            <div class="app-item-info">
                <div class="app-item-icon">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <rect x="3" y="3" width="18" height="18" rx="2"/>
                        <path d="M9 12h6"/>
                        <path d="M12 9v6"/>
                    </svg>
                </div>
                <span class="app-item-name">${escapeHtml(pkg)}</span>
            </div>
            <button class="app-item-delete" onclick="removePackage('${pkg.replace(/'/g, "\\'")}')" title="删除">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="M18 6L6 18M6 6l12 12"/>
                </svg>
            </button>
        </div>
    `).join('');
}

async function updateStats() {
    try {
        const appCount = document.getElementById('app-count');
        const protectStatus = document.getElementById('protect-status');
        const daemonStatus = document.getElementById('daemon-status');
        const statusBadge = document.getElementById('status-badge');
        
        if (appCount) appCount.textContent = currentPackages.length;
        
        const statusResult = await runCmd(`sh "${MANAGER}" status`, 5000);
        const status = {};
        if (statusResult.success) {
            statusResult.stdout.split(/\r?\n/).forEach(line => {
                const idx = line.indexOf('=');
                if (idx > 0) status[line.slice(0, idx)] = line.slice(idx + 1);
            });
        }

        const isProtected = status.protected === '1';
        const isRunning = status.daemon === '1';
        
        if (protectStatus) {
            protectStatus.textContent = isProtected ? '✓' : '!';
            protectStatus.style.color = isProtected ? '#4CAF50' : '#FF9800';
        }
        
        if (daemonStatus) {
            daemonStatus.textContent = isRunning ? '●' : '○';
            daemonStatus.style.color = isRunning ? '#4CAF50' : '#FF9800';
        }
        
        if (statusBadge) {
            if (isRunning && isProtected) {
                statusBadge.innerHTML = '<span class="status-dot"></span><span class="status-text">保护中</span>';
            } else {
                statusBadge.innerHTML = '<span class="status-dot" style="background:#FF9800"></span><span class="status-text">待保护</span>';
            }
        }
    } catch (e) {
        console.error('[DeviceIdle] updateStats error:', e);
    }
}

// ========== 7. Modal 管理 ==========

function showModal(id) {
    const modal = document.getElementById(id);
    if (modal) modal.classList.add('active');
}

function hideModal(id) {
    const modal = document.getElementById(id);
    if (modal) modal.classList.remove('active');
}

function hideAllModals() {
    document.querySelectorAll('.modal').forEach(m => m.classList.remove('active'));
}

function showConfirm(title, message, callback) {
    const titleEl = document.getElementById('confirm-title');
    const msgEl = document.getElementById('confirm-message');
    if (titleEl) titleEl.textContent = title;
    if (msgEl) msgEl.textContent = message;
    confirmCallback = callback;
    showModal('modal-confirm');
}

// ========== 8. 事件监听器注册 ==========

function setupEventListeners() {
    console.log('[DeviceIdle] Setting up event listeners...');
    
    // Add button
    const btnAdd = document.getElementById('btn-add');
    if (btnAdd) {
        btnAdd.addEventListener('click', () => {
            const inputPackage = document.getElementById('input-package');
            const inputBatch = document.getElementById('input-batch');
            if (inputPackage) inputPackage.value = '';
            if (inputBatch) inputBatch.value = '';
            showModal('modal-add');
        });
    }
    
    // Confirm add
    const btnConfirmAdd = document.getElementById('btn-confirm-add');
    if (btnConfirmAdd) {
        btnConfirmAdd.addEventListener('click', async () => {
            const inputPackage = document.getElementById('input-package');
            const inputBatch = document.getElementById('input-batch');
            const single = inputPackage ? inputPackage.value.trim() : '';
            const batch = inputBatch ? inputBatch.value.trim() : '';
            
            if (single) await addPackage(single);
            if (batch) await addPackages(batch.split('\n'));
            
            if (!single && !batch) {
                showToast('请输入包名', 'error');
                return;
            }
            
            hideModal('modal-add');
        });
    }
    
    // Import button
    const btnImport = document.getElementById('btn-import');
    if (btnImport) {
        btnImport.addEventListener('click', () => {
            const inputImport = document.getElementById('input-import');
            const chkReplace = document.getElementById('chk-replace');
            if (inputImport) inputImport.value = '';
            if (chkReplace) chkReplace.checked = false;
            showModal('modal-import');
        });
    }
    
    // Confirm import
    const btnConfirmImport = document.getElementById('btn-confirm-import');
    if (btnConfirmImport) {
        btnConfirmImport.addEventListener('click', async () => {
            const inputImport = document.getElementById('input-import');
            const chkReplace = document.getElementById('chk-replace');
            const text = inputImport ? inputImport.value : '';
            const replace = chkReplace ? chkReplace.checked : false;
            
            if (text.trim()) {
                await importPackages(text, replace);
                hideModal('modal-import');
            } else {
                showToast('请输入内容', 'error');
            }
        });
    }
    
    // Export button
    const btnExport = document.getElementById('btn-export');
    if (btnExport) {
        btnExport.addEventListener('click', () => {
            const outputExport = document.getElementById('output-export');
            if (outputExport) outputExport.value = exportPackages();
            showModal('modal-export');
        });
    }
    
    // Copy export
    const btnCopyExport = document.getElementById('btn-copy-export');
    if (btnCopyExport) {
        btnCopyExport.addEventListener('click', () => {
            const outputExport = document.getElementById('output-export');
            if (outputExport) {
                outputExport.select();
                document.execCommand('copy');
                showToast('已复制到剪贴板');
            }
        });
    }
    
    // Restore button
    const btnRestore = document.getElementById('btn-restore');
    if (btnRestore) {
        btnRestore.addEventListener('click', () => {
            showConfirm(
                '恢复原始配置',
                '这将覆盖当前所有自定义设置，恢复首次安装时的原始配置。确定继续吗？',
                async () => {
                    await restoreOriginal();
                    hideModal('modal-confirm');
                }
            );
        });
    }
    
    // Confirm action
    const btnConfirmAction = document.getElementById('btn-confirm-action');
    if (btnConfirmAction) {
        btnConfirmAction.addEventListener('click', () => {
            if (confirmCallback) {
                confirmCallback();
            }
        });
    }
    
    // Close modals
    document.querySelectorAll('.modal-close, .modal-overlay').forEach(el => {
        el.addEventListener('click', () => {
            hideAllModals();
        });
    });
    
    // Search
    const searchInput = document.getElementById('search-input');
    const clearBtn = document.getElementById('clear-search');
    
    if (searchInput) {
        searchInput.addEventListener('input', (e) => {
            updateAppList(e.target.value);
        });
    }
    
    if (clearBtn) {
        clearBtn.addEventListener('click', () => {
            if (searchInput) searchInput.value = '';
            updateAppList('');
        });
    }
    
    console.log('[DeviceIdle] Event listeners registered');
}

// ========== 9. 初始化 ==========

async function init() {
    console.log('[DeviceIdle] Initializing...');
    
    // 先注册事件监听器（确保按钮可用）
    setupEventListeners();
    
    // 然后加载数据（即使失败也不阻塞）
    try {
        await loadPackages();
    } catch (e) {
        console.error('[DeviceIdle] Initialization failed:', e);
        showToast('初始化失败: ' + e.message, 'error');
    }
    
    // 启动定时刷新
    setInterval(() => {
        updateStats().catch(e => console.error('[DeviceIdle] updateStats error:', e));
    }, 5000);
    
    console.log('[DeviceIdle] Initialization complete');
}

// 启动
document.addEventListener('DOMContentLoaded', () => {
    init().catch(e => {
        console.error('[DeviceIdle] Fatal init error:', e);
    });
});

// 全局函数暴露
window.addPackage = addPackage;
window.addPackages = addPackages;
window.importPackages = importPackages;
