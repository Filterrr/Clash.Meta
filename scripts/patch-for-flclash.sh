#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> [1/7] Replacing CMFA feature flags with Android feature flags"

if [ -f constant/features/cmfa.go ]; then
    rm constant/features/cmfa.go
    echo "    Removed constant/features/cmfa.go"
fi
if [ -f constant/features/cmfa_stub.go ]; then
    rm constant/features/cmfa_stub.go
    echo "    Removed constant/features/cmfa_stub.go"
fi

cat > constant/features/android.go << 'GOEOF'
//go:build android

package features

const Android = true
GOEOF
echo "    Created constant/features/android.go"

cat > constant/features/android_stub.go << 'GOEOF'
//go:build !android

package features

const Android = false
GOEOF
echo "    Created constant/features/android_stub.go"

echo "==> [2/7] Replacing features.CMFA references with features.Android"

sed -i 's/features\.CMFA/features.Android/g' component/loopback/detector.go
echo "    Patched component/loopback/detector.go"

sed -i 's/features\.CMFA/features.Android/g' tunnel/tunnel.go
echo "    Patched tunnel/tunnel.go"

sed -i 's/features\.CMFA/features.Android/g' constant/path.go
echo "    Patched constant/path.go"

echo "==> [3/7] Updating build tags from 'android && cmfa' to 'android'"

sed -i 's|//go:build android && cmfa|//go:build android|g' dns/patch_android.go
echo "    Patched dns/patch_android.go build tag"

sed -i 's|//go:build android && cmfa|//go:build android|g' hub/route/patch_android.go
echo "    Patched hub/route/patch_android.go build tag"

sed -i 's|//go:build !(android && cmfa)|//go:build !android|g' dns/system_common.go
echo "    Patched dns/system_common.go build tag"

echo "==> [4/7] Replacing upstream CMFA-specific files with FlClash versions"

if [ -f listener/sing_tun/server_notandroid.go ]; then
    rm listener/sing_tun/server_notandroid.go
    echo "    Removed listener/sing_tun/server_notandroid.go"
fi

cat > listener/sing_tun/server_android.go << 'GOEOF'
//go:build android

package sing_tun

import (
	tun "github.com/metacubex/sing-tun"
)

func (l *Listener) buildAndroidRules(tunOptions *tun.Options) error {
	return nil
}
GOEOF
echo "    Rewrote listener/sing_tun/server_android.go (simplified for FlClash)"

sed -i '/err = l\.buildAndroidRules(&tunOptions)/,/return$/d' listener/sing_tun/server.go 2>/dev/null || true
if ! grep -q 'buildAndroidRules' listener/sing_tun/server.go; then
    sed -i '/tunOptions\.Inet4AddressOverride = tunOptions\.Inet4Address/a\\n\terr = l.buildAndroidRules(\&tunOptions)\n\tif err != nil {\n\t\terr = E.Cause(err, "build android rules")\n\t\treturn\n\t}' listener/sing_tun/server.go 2>/dev/null || true
fi

echo "==> [5/7] Patching existing upstream files for FlClash adaptation"

sed -i 's/if features\.CMFA {/if features.Android {/g' constant/features/tags.go 2>/dev/null || true
sed -i '/if features\.Android {/,/}/s/CMFA/Android/' constant/features/tags.go 2>/dev/null || true
sed -i 's/"cmfa"/"android"/g' constant/features/tags.go
echo "    Patched constant/features/tags.go"

sed -i 's/if p\.allowUnsafePath || features\.CMFA/if p.allowUnsafePath || features.Android/' constant/path.go
echo "    Patched constant/path.go (features.CMFA -> features.Android)"

if ! grep -q 'GEOIP.metadb' constant/path.go; then
    sed -i '/strings\.EqualFold(fi\.Name(), "geoip\.metadb")/a\\t\t\t\tstrings.EqualFold(fi.Name(), "GEOIP.metadb") ||' constant/path.go
fi
if ! grep -q 'GEOIP.dat' constant/path.go; then
    sed -i '/strings\.EqualFold(fi\.Name(), "GeoIP\.dat")/a\\t\t\t\tstrings.EqualFold(fi.Name(), "GEOIP.dat") ||' constant/path.go
fi
if ! grep -q 'GEOSITE.dat' constant/path.go; then
    sed -i '/strings\.EqualFold(fi\.Name(), "GeoSite\.dat")/a\\t\t\t\tstrings.EqualFold(fi.Name(), "GEOSITE.dat") ||' constant/path.go
fi
echo "    Patched constant/path.go (added uppercase geo filename variants)"

sed -i 's/never change type traits because.*used in CFMA/never change type traits because it'\''s used in CMFA/' component/process/process.go 2>/dev/null || true
echo "    Patched component/process/process.go (typo fix)"

sed -i 's/log\.Errorln("\[Provider\]/log.Warnln("[Provider]/g' component/resource/fetcher.go
echo "    Patched component/resource/fetcher.go (Errorln -> Warnln for provider errors)"

sed -i 's/log\.Errorln("initial proxy provider/log.Warnln("initial proxy provider/g' hub/executor/executor.go
sed -i 's/log\.Errorln("initial rule provider/log.Warnln("initial rule provider/g' hub/executor/executor.go
echo "    Patched hub/executor/executor.go (Errorln -> Warnln for provider init errors)"

sed -i 's/updateListeners(cfg\.General, cfg\.Listeners, force)/\/\/updateListeners(cfg.General, cfg.Listeners, force)/' hub/executor/executor.go
sed -i 's/updateTun(cfg\.General)/\/\/updateTun(cfg.General)/' hub/executor/executor.go
echo "    Patched hub/executor/executor.go (commented out updateListeners and updateTun)"

if grep -q 'wg\.Wait()' hub/executor/executor.go; then
    sed -i '/wg\.Wait()/d' hub/executor/executor.go
    echo "    Removed wg.Wait() from hub/executor/executor.go"
fi

sed -i 's/if err = server\.Serve(l); err != nil {/_ = server.Serve(l)/' hub/route/server.go
sed -i '/log\.Errorln("External controller serve error: %s", err)/d' hub/route/server.go
if grep -q '_ = server.Serve(l)' hub/route/server.go; then
    :
else
    sed -i 's/if err = server\.Serve(l); err != nil {/_ = server.Serve(l)/' hub/route/server.go
fi
echo "    Patched hub/route/server.go (ignore Serve error)"

sed -i 's/if tunConf\.Equal(LastTunConf) {/if tunLister != nil \&\& tunConf.Equal(LastTunConf) {/' listener/listener.go
sed -i '/if tunLister != nil {/d' listener/listener.go
sed -i '/tunLister\.OnReload()/d' listener/listener.go
if ! grep -q 'tunLister.OnReload()' listener/listener.go; then
    sed -i 's/if tunLister != nil && tunConf\.Equal(LastTunConf) {/if tunLister != nil \&\& tunConf.Equal(LastTunConf) {\n\t\ttunLister.OnReload()/' listener/listener.go
fi
echo "    Patched listener/listener.go (tunLister nil check reorder)"

if grep -q 'var DefaultTestURL = ' constant/adapters.go; then
    sed -i '/^var DefaultTestURL = /d' constant/adapters.go
    sed -i 's/DefaultTestURL[[:space:]]*=/DefaultTestURL =/' constant/adapters.go 2>/dev/null || true
fi
echo "    Patched constant/adapters.go (DefaultTestURL moved to const block)"

sed -i 's/if !features\.CMFA {/if !features.Android {/' tunnel/tunnel.go
echo "    Patched tunnel/tunnel.go (features.CMFA -> features.Android)"

echo "==> [6/7] Creating FlClash-specific patch files"

cat > adapter/patch.go << 'GOEOF'
package adapter

type UrlTestCheck func(url string, name string, delay uint16)

var UrlTestHook UrlTestCheck
GOEOF
echo "    Created adapter/patch.go"

if ! grep -q 'UrlTestHook' adapter/adapter.go; then
    sed -i '/URLTest\(ctx context.Context, url string, expectedStatus/i\\tif UrlTestHook != nil {\n\t\tUrlTestHook(url, p.Name(), t)\n\t}\n' adapter/adapter.go
fi
echo "    Patched adapter/adapter.go (added UrlTestHook call)"

cat > adapter/provider/patch.go << 'GOEOF'
package provider

func (pp *proxySetProvider) GetSubscriptionInfo() *SubscriptionInfo {
	return pp.subscriptionInfo
}
GOEOF
echo "    Created adapter/provider/patch.go"

cat > component/updater/patch.go << 'GOEOF'
package updater

import (
	"fmt"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/oschwald/maxminddb-golang"
)

func UpdateMMDBWithPath(path string) (err error) {
	defer mmdb.ReloadIP()
	data, err := downloadForBytes(geodata.MmdbUrl())
	if err != nil {
		return fmt.Errorf("can't download MMDB database file: %w", err)
	}
	instance, err := maxminddb.FromBytes(data)
	if err != nil {
		return fmt.Errorf("invalid MMDB database file: %s", err)
	}
	_ = instance.Close()

	mmdb.IPInstance().Reader.Close()
	if err = saveFile(data, path); err != nil {
		return fmt.Errorf("can't save MMDB database file: %w", err)
	}
	return nil
}

func UpdateASNWithPath(path string) (err error) {
	defer mmdb.ReloadASN()
	data, err := downloadForBytes(geodata.ASNUrl())
	if err != nil {
		return fmt.Errorf("can't download ASN database file: %w", err)
	}

	instance, err := maxminddb.FromBytes(data)
	if err != nil {
		return fmt.Errorf("invalid ASN database file: %s", err)
	}
	_ = instance.Close()

	mmdb.ASNInstance().Reader.Close()
	if err = saveFile(data, path); err != nil {
		return fmt.Errorf("can't save ASN database file: %w", err)
	}
	return nil
}

func UpdateGeoIpWithPath(path string) (err error) {
	geoLoader, err := geodata.GetGeoDataLoader("standard")
	data, err := downloadForBytes(geodata.GeoIpUrl())
	if err != nil {
		return fmt.Errorf("can't download GeoIP database file: %w", err)
	}
	if _, err = geoLoader.LoadIPByBytes(data, "cn"); err != nil {
		return fmt.Errorf("invalid GeoIP database file: %s", err)
	}
	if err = saveFile(data, path); err != nil {
		return fmt.Errorf("can't save GeoIP database file: %w", err)
	}
	return nil
}

func UpdateGeoSiteWithPath(path string) (err error) {
	geoLoader, err := geodata.GetGeoDataLoader("standard")
	data, err := downloadForBytes(geodata.GeoSiteUrl())
	if err != nil {
		return fmt.Errorf("can't download GeoSite database file: %w", err)
	}

	if _, err = geoLoader.LoadSiteByBytes(data, "cn"); err != nil {
		return fmt.Errorf("invalid GeoSite database file: %s", err)
	}

	if err = saveFile(data, path); err != nil {
		return fmt.Errorf("can't save GeoSite database file: %w", err)
	}
	return nil
}
GOEOF
echo "    Created component/updater/patch.go"

cat > config/patch.go << 'GOEOF'
package config

import "sync"

var (
	proxyNameList   []string
	proxyNameListMu sync.RWMutex
)

func GetProxyNameList() []string {
	proxyNameListMu.RLock()
	defer proxyNameListMu.RUnlock()
	return proxyNameList
}

func SetProxyNameList(list []string) {
	proxyNameListMu.Lock()
	defer proxyNameListMu.Unlock()
	proxyNameList = list
}
GOEOF
echo "    Created config/patch.go"

if ! grep -q 'SetProxyNameList' config/config.go; then
    sed -i '/proxies = list/a\\tSetProxyNameList(proxyList)' config/config.go 2>/dev/null || true
fi
echo "    Patched config/config.go (added SetProxyNameList call)"

cat > hub/executor/patch.go << 'GOEOF'
package executor

type ProviderLoadedHook func(providerName string)

var DefaultProviderLoadedHook ProviderLoadedHook
GOEOF
echo "    Created hub/executor/patch.go"

if ! grep -q 'DefaultProviderLoadedHook' hub/executor/executor.go; then
    sed -i '/log.Warnln("initial proxy provider %s error: %v", name, err)/a\\t\t} else {\n\t\t\tif DefaultProviderLoadedHook != nil {\n\t\t\t\tDefaultProviderLoadedHook(name)\n\t\t\t}' hub/executor/executor.go
fi
echo "    Patched hub/executor/executor.go (added ProviderLoadedHook call)"

cat > listener/patch.go << 'GOEOF'
package listener

func StopListener() {

	if socksListener != nil {
		_ = socksListener.Close()
		socksListener = nil
	}

	if socksUDPListener != nil {
		_ = socksUDPListener.Close()
		socksUDPListener = nil
	}

	if httpListener != nil {
		_ = httpListener.Close()
		httpListener = nil
	}

	if redirListener != nil {
		_ = redirListener.Close()
		redirListener = nil
	}

	if redirUDPListener != nil {
		_ = redirUDPListener.Close()
		redirUDPListener = nil
	}

	if tproxyListener != nil {
		_ = tproxyListener.Close()
		tproxyListener = nil
	}

	if tproxyUDPListener != nil {
		_ = tproxyUDPListener.Close()
		tproxyUDPListener = nil
	}

	if mixedListener != nil {
		_ = mixedListener.Close()
		mixedListener = nil
	}

	if mixedUDPLister != nil {
		_ = mixedUDPLister.Close()
		mixedUDPLister = nil
	}

	if tunLister != nil {
		_ = tunLister.Close()
		tunLister = nil
	}

	if shadowSocksListener != nil {
		_ = shadowSocksListener.Close()
		shadowSocksListener = nil
	}

	if shadowSocksListener != nil {
		_ = shadowSocksListener.Close()
		shadowSocksListener = nil
	}

	if vmessListener != nil {
		_ = vmessListener.Close()
		vmessListener = nil
	}

	if tuicListener != nil {
		_ = tuicListener.Close()
		tuicListener = nil
	}
}
GOEOF
echo "    Created listener/patch.go"

cat > tunnel/patch.go << 'GOEOF'
package tunnel

import (
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

var (
	allProxies = make(map[string]C.Proxy)
)

func AllProxies() map[string]C.Proxy {
	return proxiesWithProviders()
}

func UpdateAllProxies(proxies map[string]C.Proxy, providers map[string]P.ProxyProvider) {
	var allProxiesTemp = make(map[string]C.Proxy)
	for name, proxy := range proxies {
		allProxiesTemp[name] = proxy
	}
	for _, p := range providers {
		for _, proxy := range p.Proxies() {
			name := proxy.Name()
			allProxiesTemp[name] = proxy
		}
	}
	allProxies = allProxiesTemp
}

func proxiesWithProviders() map[string]C.Proxy {
	ap := make(map[string]C.Proxy)
	for name, proxy := range Proxies() {
		ap[name] = proxy
	}
	for _, p := range Providers() {
		for _, proxy := range p.Proxies() {
			name := proxy.Name()
			ap[name] = proxy
		}
	}
	return ap
}
GOEOF
echo "    Created tunnel/patch.go"

if ! grep -q 'UpdateAllProxies' tunnel/tunnel.go; then
    sed -i '/UpdateTun()/a\\tUpdateAllProxies(newProxies, newProviders)' tunnel/tunnel.go
fi
echo "    Patched tunnel/tunnel.go (added UpdateAllProxies call)"

cat > tunnel/statistic/patch.go << 'GOEOF'
package statistic

type RequestNotify func(c Tracker)

var DefaultRequestNotify RequestNotify

func (m *Manager) TotalTraffic(onlyProxy bool) (up, down int64) {
	if onlyProxy {
		return m.proxyUploadTotal.Load(), m.proxyDownloadTotal.Load()
	}
	return m.uploadTotal.Load(), m.downloadTotal.Load()
}

func (m *Manager) NowTraffic(onlyProxy bool) (up, down int64) {
	if onlyProxy {
		return m.proxyUploadBlip.Load(), m.proxyDownloadBlip.Load()
	}
	return m.uploadBlip.Load(), m.downloadBlip.Load()
}
GOEOF
echo "    Created tunnel/statistic/patch.go"

cat > tunnel/statistic/patch_android.go << 'GOEOF'
//go:build android

package statistic
GOEOF
echo "    Created tunnel/statistic/patch_android.go"

cat > listener/http/patch_android.go << 'GOEOF'
//go:build android

package http

import "net"

func (l *Listener) Listener() net.Listener {
	return l.listener
}
GOEOF
echo "    Created listener/http/patch_android.go"

cat > rules/provider/patch_android.go << 'GOEOF'
//go:build android

package provider

import "time"

var (
	suspended bool
)

type UpdatableProvider interface {
	UpdatedAt() time.Time
}

func Suspend(s bool) {
	suspended = s
}
GOEOF
echo "    Created rules/provider/patch_android.go"

echo "==> [7/7] Patching traffic statistics for proxy-only tracking"

if ! grep -q 'proxyUploadTemp' tunnel/statistic/manager.go; then
    sed -i '/downloadTotal.*atomic\.Int64/a\\tproxyUploadTemp    atomic.Int64\n\tproxyDownloadTemp  atomic.Int64\n\tproxyUploadBlip    atomic.Int64\n\tproxyDownloadBlip  atomic.Int64\n\tproxyUploadTotal   atomic.Int64\n\tproxyDownloadTotal atomic.Int64' tunnel/statistic/manager.go
fi
echo "    Added proxy traffic fields to manager.go"

if ! grep -q 'DefaultRequestNotify' tunnel/statistic/manager.go; then
    sed -i '/manager.Join(c)/i\\tif DefaultRequestNotify != nil {\n\t\tDefaultRequestNotify(c)\n\t}' tunnel/statistic/manager.go
fi
echo "    Added DefaultRequestNotify call to manager.go"

sed -i 's/func (m \*Manager) PushUploaded(size int64)/func (m *Manager) PushUploaded(lastChain string, size int64)/' tunnel/statistic/manager.go
sed -i 's/func (m \*Manager) PushDownloaded(size int64)/func (m *Manager) PushDownloaded(lastChain string, size int64)/' tunnel/statistic/manager.go

if ! grep -q 'proxyUploadTemp' tunnel/statistic/manager.go || ! grep -q 'lastChain' tunnel/statistic/manager.go; then
    echo "    WARNING: Could not fully patch PushUploaded/PushDownloaded signatures, manual review needed"
fi

sed -i 's/m\.PushUploaded(upload)/m.PushUploaded("", upload)/g' tunnel/statistic/manager.go 2>/dev/null || true
sed -i 's/m\.PushDownloaded(download)/m.PushDownloaded("", download)/g' tunnel/statistic/manager.go 2>/dev/null || true
echo "    Patched PushUploaded/PushDownloaded in manager.go"

sed -i 's/manager\.PushUploaded(uploadTotal)/manager.PushUploaded("", uploadTotal)/g' tunnel/statistic/tracker.go 2>/dev/null || true
sed -i 's/manager\.PushDownloaded(downloadTotal)/manager.PushDownloaded("", downloadTotal)/g' tunnel/statistic/tracker.go 2>/dev/null || true
sed -i 's/manager\.PushUploaded(upload)/manager.PushUploaded("", upload)/g' tunnel/statistic/tracker.go 2>/dev/null || true
sed -i 's/manager\.PushDownloaded(download)/manager.PushDownloaded("", download)/g' tunnel/statistic/tracker.go 2>/dev/null || true
echo "    Patched PushUploaded/PushDownloaded calls in tracker.go"

echo ""
echo "==> All FlClash patches applied successfully!"
echo "    Please review the changes with 'git diff' before committing."
