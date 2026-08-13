package simslim

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDerivedDataScanMeasuresDirectGeneratedDirectories(t *testing.T) {
	root := filepath.Join(t.TempDir(), "DerivedData")
	projectDirectory := filepath.Join(root, "FleetDog-gqunbotdqvgsfeemshfcnsyrblmp")
	cacheDirectory := filepath.Join(root, "ModuleCache.noindex")
	otherDirectory := filepath.Join(root, "Unclassified")
	writeTestFile(t, filepath.Join(projectDirectory, "Build", "large.bin"), 96*1024)
	writeTestFile(t, filepath.Join(cacheDirectory, "module.bin"), 64*1024)
	writeTestFile(t, filepath.Join(otherDirectory, "other.bin"), 32*1024)
	writeTestFile(t, filepath.Join(root, ".DS_Store"), 128*1024)

	modified := time.Unix(1_700_000_000, 0)
	if err := os.Chtimes(projectDirectory, modified, modified); err != nil {
		t.Fatal(err)
	}

	outside := filepath.Join(t.TempDir(), "outside")
	writeTestFile(t, filepath.Join(outside, "keep.bin"), 256*1024)
	if err := os.Symlink(outside, filepath.Join(root, "LinkedData")); err != nil {
		t.Fatal(err)
	}

	scan, err := scanDerivedDataAt(context.Background(), root)
	if err != nil {
		t.Fatalf("scanDerivedDataAt() error = %v", err)
	}
	if len(scan.Entries) != 3 {
		t.Fatalf("entries = %d, want 3: %#v", len(scan.Entries), scan.Entries)
	}
	if scan.Entries[0].ID != filepath.Base(projectDirectory) {
		t.Errorf("largest entry = %q, want project", scan.Entries[0].ID)
	}

	byID := map[string]DerivedDataEntry{}
	var summed int64
	for _, entry := range scan.Entries {
		byID[entry.ID] = entry
		summed += entry.Bytes
	}
	project := byID[filepath.Base(projectDirectory)]
	if project.Name != "FleetDog" || project.Kind != "project" {
		t.Errorf("project display info = %#v", project)
	}
	if project.ModifiedAt != modified.Unix() {
		t.Errorf("modifiedAt = %d, want %d", project.ModifiedAt, modified.Unix())
	}
	if cache := byID["ModuleCache.noindex"]; cache.Kind != "cache" {
		t.Errorf("cache kind = %q, want cache", cache.Kind)
	}
	if scan.TotalBytes != summed {
		t.Errorf("totalBytes = %d, want summed entries %d", scan.TotalBytes, summed)
	}
	if _, ok := byID["LinkedData"]; ok {
		t.Error("scan must not include symlinked directories")
	}
	if _, ok := byID[".DS_Store"]; ok {
		t.Error("scan must not include files")
	}
}

func TestDerivedDataCleanupDeletesOnlySelectedDirectChildren(t *testing.T) {
	root := filepath.Join(t.TempDir(), "DerivedData")
	removeDirectory := filepath.Join(root, "RemoveMe-abcdefghijklmnopqrstuvwxyzab")
	keepDirectory := filepath.Join(root, "KeepMe-abcdefghijklmnopqrstuvwxyzab")
	writeTestFile(t, filepath.Join(removeDirectory, "Build", "remove.bin"), 64*1024)
	writeTestFile(t, filepath.Join(keepDirectory, "Build", "keep.bin"), 64*1024)

	result, err := cleanDerivedDataAt(
		context.Background(),
		root,
		[]string{filepath.Base(removeDirectory)},
	)
	if err != nil {
		t.Fatalf("cleanDerivedDataAt() error = %v", err)
	}
	if result.ReclaimedBytes == 0 || result.BeforeBytes == 0 {
		t.Errorf("cleanup result did not report reclaimed data: %#v", result)
	}
	if len(result.DeletedEntryIDs) != 1 || result.DeletedEntryIDs[0] != filepath.Base(removeDirectory) {
		t.Errorf("deleted entries = %#v", result.DeletedEntryIDs)
	}
	if _, err := os.Lstat(removeDirectory); !os.IsNotExist(err) {
		t.Errorf("selected directory still exists: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(keepDirectory, "Build", "keep.bin")); err != nil {
		t.Errorf("cleanup touched unselected directory: %v", err)
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		t.Errorf("cleanup must preserve DerivedData root: %v", err)
	}
}

func TestDerivedDataCleanupRejectsTraversalAndSymlinks(t *testing.T) {
	root := filepath.Join(t.TempDir(), "DerivedData")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside")
	outsideFile := filepath.Join(outside, "keep.bin")
	writeTestFile(t, outsideFile, 64*1024)
	if err := os.Symlink(outside, filepath.Join(root, "LinkedData")); err != nil {
		t.Fatal(err)
	}

	for _, id := range []string{"..", "../outside", "nested/child", ""} {
		if _, err := cleanDerivedDataAt(context.Background(), root, []string{id}); err == nil {
			t.Errorf("cleanup accepted unsafe entry ID %q", id)
		}
	}
	if _, err := cleanDerivedDataAt(context.Background(), root, []string{"LinkedData"}); err == nil {
		t.Error("cleanup accepted a symlinked entry")
	}
	if _, err := os.Lstat(outsideFile); err != nil {
		t.Fatalf("cleanup touched data outside DerivedData: %v", err)
	}
}

func TestDerivedDataScanAllowsMissingRoot(t *testing.T) {
	root := filepath.Join(t.TempDir(), "missing", "DerivedData")
	scan, err := scanDerivedDataAt(context.Background(), root)
	if err != nil {
		t.Fatalf("scanDerivedDataAt() error = %v", err)
	}
	if scan.RootPath == "" || scan.TotalBytes != 0 || scan.Entries == nil || len(scan.Entries) != 0 {
		t.Errorf("unexpected empty scan: %#v", scan)
	}
}

func TestDerivedDataRootMustBeExplicitlyNamed(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "keep", "important.bin"), 64*1024)

	if _, err := scanDerivedDataAt(context.Background(), root); err == nil {
		t.Error("scan accepted a broad root not named DerivedData")
	}
	if _, err := cleanDerivedDataAt(context.Background(), root, []string{"keep"}); err == nil {
		t.Error("cleanup accepted a broad root not named DerivedData")
	}
	if _, err := os.Lstat(filepath.Join(root, "keep", "important.bin")); err != nil {
		t.Fatalf("unsafe-root validation touched data: %v", err)
	}
}

func TestDerivedDataDisplayInfoOnlyStripsXcodeHashes(t *testing.T) {
	tests := []struct {
		directoryName string
		name          string
		kind          string
	}{
		{"FleetDog-gqunbotdqvgsfeemshfcnsyrblmp", "FleetDog", "project"},
		{"My-Hyphenated-App-abcdefghijklmnopqrstuvwxyzab", "My-Hyphenated-App", "project"},
		{"ModuleCache.noindex", "ModuleCache.noindex", "cache"},
		{"ordinary-folder", "ordinary-folder", "other"},
		{"Project-ABCDEF0123456789", "Project-ABCDEF0123456789", "other"},
	}
	for _, test := range tests {
		name, kind := derivedDataDisplayInfo(test.directoryName)
		if name != test.name || kind != test.kind {
			t.Errorf(
				"derivedDataDisplayInfo(%q) = (%q, %q), want (%q, %q)",
				test.directoryName,
				name,
				kind,
				test.name,
				test.kind,
			)
		}
	}
}

func TestDerivedDataMetadataReadsWorkspaceBuildAndPackageVersions(t *testing.T) {
	projectRoot := filepath.Join(t.TempDir(), "FleetDog")
	workspacePath := filepath.Join(projectRoot, "ios", "FleetDog.xcworkspace")
	if err := os.MkdirAll(workspacePath, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTextFile(
		t,
		filepath.Join(projectRoot, "package.json"),
		`{"name":"fleetdog","version":"2.9.0"}`,
	)

	entryPath := filepath.Join(t.TempDir(), "DerivedData", "FleetDog-abcdefghijklmnopqrstuvwxyzab")
	writeTextFile(
		t,
		filepath.Join(entryPath, "info.plist"),
		testPlist(map[string]string{"WorkspacePath": workspacePath}),
	)
	appPath := filepath.Join(
		entryPath,
		"Build",
		"Products",
		"Debug-iphonesimulator",
		"FleetDog.app",
	)
	writeTextFile(
		t,
		filepath.Join(appPath, "Info.plist"),
		testPlist(map[string]string{
			"CFBundleDisplayName":        "FleetDog",
			"CFBundleIdentifier":         "com.fleetdog",
			"CFBundleShortVersionString": "2.9.0",
			"CFBundleVersion":            "248",
			"DTPlatformName":             "iphonesimulator",
			"DTSDKName":                  "iphonesimulator26.5",
			"MinimumOSVersion":           "16.4",
		}),
	)
	builtAt := time.Unix(1_750_000_000, 0)
	if err := os.Chtimes(appPath, builtAt, builtAt); err != nil {
		t.Fatal(err)
	}

	metadata, err := inspectDerivedDataMetadata(context.Background(), entryPath, "project")
	if err != nil {
		t.Fatalf("inspectDerivedDataMetadata() error = %v", err)
	}
	if metadata.sourcePath != workspacePath || !metadata.sourceExists {
		t.Errorf("source metadata = (%q, %t), want existing %q", metadata.sourcePath, metadata.sourceExists, workspacePath)
	}
	if metadata.packageName != "fleetdog" || metadata.packageVersion != "2.9.0" {
		t.Errorf("package metadata = (%q, %q)", metadata.packageName, metadata.packageVersion)
	}
	if metadata.bundleIdentifier != "com.fleetdog" ||
		metadata.marketingVersion != "2.9.0" ||
		metadata.buildNumber != "248" {
		t.Errorf("app identity metadata = %#v", metadata)
	}
	if metadata.configuration != "Debug" ||
		metadata.platform != "iphonesimulator" ||
		metadata.sdk != "iphonesimulator26.5" ||
		metadata.minimumOSVersion != "16.4" {
		t.Errorf("build context metadata = %#v", metadata)
	}
	if metadata.productPath != appPath || metadata.productModifiedAt != builtAt.Unix() {
		t.Errorf("product metadata = (%q, %d)", metadata.productPath, metadata.productModifiedAt)
	}
}

func TestNewestBuiltAppPrefersNewestNonTestProduct(t *testing.T) {
	productsRoot := filepath.Join(t.TempDir(), "Products")
	debugApp := filepath.Join(productsRoot, "Debug-iphonesimulator", "FleetDog.app")
	releaseApp := filepath.Join(productsRoot, "Release-iphoneos", "FleetDog.app")
	testRunner := filepath.Join(
		productsRoot,
		"Debug-iphonesimulator",
		"FleetDogUITests-Runner.app",
	)
	for _, appPath := range []string{debugApp, releaseApp, testRunner} {
		writeTextFile(t, filepath.Join(appPath, "Info.plist"), testPlist(nil))
	}
	if err := os.Chtimes(debugApp, time.Unix(100, 0), time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(releaseApp, time.Unix(200, 0), time.Unix(200, 0)); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(testRunner, time.Unix(300, 0), time.Unix(300, 0)); err != nil {
		t.Fatal(err)
	}

	candidate, ok, err := newestBuiltApp(context.Background(), productsRoot)
	if err != nil {
		t.Fatalf("newestBuiltApp() error = %v", err)
	}
	if !ok || candidate.path != releaseApp {
		t.Fatalf("candidate = %#v, found = %t; want %q", candidate, ok, releaseApp)
	}
	if candidate.configuration != "Release" {
		t.Errorf("configuration = %q, want Release", candidate.configuration)
	}
}

func TestDerivedDataMetadataMarksMissingSource(t *testing.T) {
	entryPath := filepath.Join(t.TempDir(), "DerivedData", "OldApp-abcdefghijklmnopqrstuvwxyzab")
	missingWorkspace := filepath.Join(t.TempDir(), "deleted", "OldApp.xcworkspace")
	writeTextFile(
		t,
		filepath.Join(entryPath, "info.plist"),
		testPlist(map[string]string{"WorkspacePath": missingWorkspace}),
	)

	metadata, err := inspectDerivedDataMetadata(context.Background(), entryPath, "project")
	if err != nil {
		t.Fatalf("inspectDerivedDataMetadata() error = %v", err)
	}
	if metadata.sourcePath != missingWorkspace || metadata.sourceExists {
		t.Errorf("missing source metadata = (%q, %t)", metadata.sourcePath, metadata.sourceExists)
	}
}

func writeTextFile(t *testing.T, target, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

func testPlist(values map[string]string) string {
	plist := `<?xml version="1.0" encoding="UTF-8"?>` +
		`<plist version="1.0"><dict>`
	for key, value := range values {
		plist += "<key>" + key + "</key><string>" + value + "</string>"
	}
	return plist + "</dict></plist>"
}
