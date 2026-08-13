package simslim

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const derivedDataPathEnvironment = "SIMSLIM_DERIVED_DATA_PATH"

// DerivedDataEntry is one direct child of Xcode's DerivedData directory.
// Direct-child IDs are the deletion contract: callers never supply an
// arbitrary filesystem path.
type DerivedDataEntry struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	DirectoryName     string `json:"directoryName"`
	Path              string `json:"path"`
	Kind              string `json:"kind"`
	Bytes             int64  `json:"bytes"`
	ModifiedAt        int64  `json:"modifiedAt"`
	SourcePath        string `json:"sourcePath,omitempty"`
	SourceExists      bool   `json:"sourceExists,omitempty"`
	PackageName       string `json:"packageName,omitempty"`
	PackageVersion    string `json:"packageVersion,omitempty"`
	PackagePath       string `json:"packagePath,omitempty"`
	ProductName       string `json:"productName,omitempty"`
	ProductPath       string `json:"productPath,omitempty"`
	BundleIdentifier  string `json:"bundleIdentifier,omitempty"`
	MarketingVersion  string `json:"marketingVersion,omitempty"`
	BuildNumber       string `json:"buildNumber,omitempty"`
	Configuration     string `json:"configuration,omitempty"`
	Platform          string `json:"platform,omitempty"`
	SDK               string `json:"sdk,omitempty"`
	MinimumOSVersion  string `json:"minimumOSVersion,omitempty"`
	ProductModifiedAt int64  `json:"productModifiedAt,omitempty"`
}

type DerivedDataScan struct {
	RootPath   string             `json:"rootPath"`
	TotalBytes int64              `json:"totalBytes"`
	Entries    []DerivedDataEntry `json:"entries"`
}

type DerivedDataCleanupResult struct {
	RootPath        string   `json:"rootPath"`
	EntryIDs        []string `json:"entryIds"`
	DeletedEntryIDs []string `json:"deletedEntryIds"`
	BeforeBytes     int64    `json:"beforeBytes"`
	AfterBytes      int64    `json:"afterBytes"`
	ReclaimedBytes  int64    `json:"reclaimedBytes"`
}

func derivedDataRoot() (string, error) {
	if override := os.Getenv(derivedDataPathEnvironment); override != "" {
		root, err := filepath.Abs(override)
		if err != nil {
			return "", fmt.Errorf("resolve derived data override: %w", err)
		}
		return filepath.Clean(root), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}
	return filepath.Join(home, "Library", "Developer", "Xcode", "DerivedData"), nil
}

// ScanDerivedData measures the generated directories directly beneath Xcode's
// DerivedData root.
func ScanDerivedData(ctx context.Context) (DerivedDataScan, error) {
	root, err := derivedDataRoot()
	if err != nil {
		return DerivedDataScan{}, err
	}
	return scanDerivedDataAt(ctx, root)
}

func scanDerivedDataAt(ctx context.Context, root string) (DerivedDataScan, error) {
	displayRoot, resolvedRoot, exists, err := resolveDerivedDataRoot(root)
	if err != nil {
		return DerivedDataScan{}, err
	}
	scan := DerivedDataScan{
		RootPath: displayRoot,
		Entries:  make([]DerivedDataEntry, 0),
	}
	if !exists {
		return scan, nil
	}

	entries, err := os.ReadDir(resolvedRoot)
	if err != nil {
		return DerivedDataScan{}, fmt.Errorf("read derived data directory: %w", err)
	}
	for _, directoryEntry := range entries {
		if err := ctx.Err(); err != nil {
			return DerivedDataScan{}, err
		}

		name := directoryEntry.Name()
		target := filepath.Join(resolvedRoot, name)
		info, err := os.Lstat(target)
		if err != nil {
			return DerivedDataScan{}, fmt.Errorf("inspect derived data entry %q: %w", name, err)
		}
		// Xcode stores generated data in directories. Ignoring files and
		// symlinks keeps both the scan and deletion surface deliberately small.
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			continue
		}
		if err := requireDirectChild(resolvedRoot, target); err != nil {
			return DerivedDataScan{}, err
		}
		if err := requireResolvedDescendant(resolvedRoot, target); err != nil {
			return DerivedDataScan{}, err
		}
		bytes, err := allocatedSize(target)
		if err != nil {
			return DerivedDataScan{}, fmt.Errorf("measure derived data entry %q: %w", name, err)
		}
		displayName, kind := derivedDataDisplayInfo(name)
		entry := DerivedDataEntry{
			ID:            name,
			Name:          displayName,
			DirectoryName: name,
			Path:          filepath.Join(displayRoot, name),
			Kind:          kind,
			Bytes:         bytes,
			ModifiedAt:    info.ModTime().Unix(),
		}
		metadata, err := inspectDerivedDataMetadata(ctx, target, kind)
		if err != nil {
			return DerivedDataScan{}, err
		}
		applyDerivedDataMetadata(&entry, metadata)
		scan.Entries = append(scan.Entries, entry)
		scan.TotalBytes += bytes
	}

	sort.Slice(scan.Entries, func(i, j int) bool {
		if scan.Entries[i].Bytes != scan.Entries[j].Bytes {
			return scan.Entries[i].Bytes > scan.Entries[j].Bytes
		}
		return scan.Entries[i].DirectoryName < scan.Entries[j].DirectoryName
	})
	return scan, nil
}

// CleanDerivedData permanently removes the selected direct children of Xcode's
// DerivedData root.
func CleanDerivedData(ctx context.Context, entryIDs []string) (DerivedDataCleanupResult, error) {
	root, err := derivedDataRoot()
	if err != nil {
		return DerivedDataCleanupResult{}, err
	}
	return cleanDerivedDataAt(ctx, root, entryIDs)
}

func cleanDerivedDataAt(ctx context.Context, root string, entryIDs []string) (DerivedDataCleanupResult, error) {
	entryIDs, err := validateDerivedDataEntryIDs(entryIDs)
	if err != nil {
		return DerivedDataCleanupResult{}, err
	}
	displayRoot, resolvedRoot, exists, err := resolveDerivedDataRoot(root)
	if err != nil {
		return DerivedDataCleanupResult{}, err
	}
	if !exists {
		return DerivedDataCleanupResult{}, fmt.Errorf("Xcode Derived Data directory does not exist: %s", displayRoot)
	}

	type cleanupTarget struct {
		id   string
		path string
	}
	targets := make([]cleanupTarget, 0, len(entryIDs))
	result := DerivedDataCleanupResult{
		RootPath: displayRoot,
		EntryIDs: entryIDs,
	}

	// Validate and measure every requested entry before deleting anything.
	for _, id := range entryIDs {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		target := filepath.Join(resolvedRoot, id)
		if err := requireDirectChild(resolvedRoot, target); err != nil {
			return result, err
		}
		info, err := os.Lstat(target)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return result, fmt.Errorf("inspect derived data entry %q: %w", id, err)
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return result, fmt.Errorf("refusing to delete non-directory derived data entry %q", id)
		}
		if err := requireResolvedDescendant(resolvedRoot, target); err != nil {
			return result, err
		}
		bytes, err := allocatedSize(target)
		if err != nil {
			return result, fmt.Errorf("measure derived data entry %q: %w", id, err)
		}
		result.BeforeBytes += bytes
		targets = append(targets, cleanupTarget{id: id, path: target})
	}

	for _, target := range targets {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		if err := os.RemoveAll(target.path); err != nil {
			return result, fmt.Errorf("delete derived data entry %q: %w", target.id, err)
		}
		result.DeletedEntryIDs = append(result.DeletedEntryIDs, target.id)
	}

	// Xcode may recreate an entry immediately if it is running. Account for
	// that so the reported reclaimed amount never overstates the result.
	for _, target := range targets {
		info, err := os.Lstat(target.path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return result, fmt.Errorf("inspect cleaned derived data entry %q: %w", target.id, err)
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			continue
		}
		bytes, err := allocatedSize(target.path)
		if err != nil {
			return result, fmt.Errorf("measure cleaned derived data entry %q: %w", target.id, err)
		}
		result.AfterBytes += bytes
	}
	result.ReclaimedBytes = result.BeforeBytes - result.AfterBytes
	if result.ReclaimedBytes < 0 {
		result.ReclaimedBytes = 0
	}
	return result, nil
}

func resolveDerivedDataRoot(root string) (displayRoot, resolvedRoot string, exists bool, err error) {
	displayRoot, err = filepath.Abs(root)
	if err != nil {
		return "", "", false, fmt.Errorf("resolve derived data directory: %w", err)
	}
	displayRoot = filepath.Clean(displayRoot)
	if filepath.Base(displayRoot) != "DerivedData" {
		return "", "", false, fmt.Errorf(
			"refusing Derived Data root not named DerivedData: %s",
			displayRoot,
		)
	}
	info, err := os.Stat(displayRoot)
	if os.IsNotExist(err) {
		return displayRoot, "", false, nil
	}
	if err != nil {
		return "", "", false, fmt.Errorf("locate derived data directory: %w", err)
	}
	if !info.IsDir() {
		return "", "", false, fmt.Errorf("Xcode Derived Data path is not a directory: %s", displayRoot)
	}
	resolvedRoot, err = filepath.EvalSymlinks(displayRoot)
	if err != nil {
		return "", "", false, fmt.Errorf("resolve derived data directory: %w", err)
	}
	resolvedInfo, err := os.Stat(resolvedRoot)
	if err != nil {
		return "", "", false, fmt.Errorf("inspect derived data directory: %w", err)
	}
	if !resolvedInfo.IsDir() {
		return "", "", false, fmt.Errorf("resolved Xcode Derived Data path is not a directory: %s", resolvedRoot)
	}
	return displayRoot, filepath.Clean(resolvedRoot), true, nil
}

func validateDerivedDataEntryIDs(ids []string) ([]string, error) {
	seen := map[string]bool{}
	validated := make([]string, 0, len(ids))
	for _, id := range ids {
		if id == "" || id == "." || id == ".." || filepath.Base(id) != id ||
			strings.ContainsRune(id, filepath.Separator) {
			return nil, fmt.Errorf("invalid derived data entry %q", id)
		}
		if seen[id] {
			continue
		}
		seen[id] = true
		validated = append(validated, id)
	}
	if len(validated) == 0 {
		return nil, fmt.Errorf("select at least one derived data entry")
	}
	sort.Strings(validated)
	return validated, nil
}

func requireDirectChild(root, target string) error {
	if err := requireDescendant(root, target); err != nil {
		return fmt.Errorf("refusing derived data path: %w", err)
	}
	relative, err := filepath.Rel(filepath.Clean(root), filepath.Clean(target))
	if err != nil {
		return fmt.Errorf("resolve derived data entry: %w", err)
	}
	if filepath.Dir(relative) != "." {
		return fmt.Errorf("refusing derived data path that is not a direct child: %s", target)
	}
	return nil
}

func derivedDataDisplayInfo(directoryName string) (name, kind string) {
	if strings.HasSuffix(directoryName, ".noindex") ||
		directoryName == "SourcePackages" ||
		directoryName == "Logs" {
		return directoryName, "cache"
	}
	if separator := strings.LastIndexByte(directoryName, '-'); separator > 0 {
		suffix := directoryName[separator+1:]
		if isXcodeDerivedDataHash(suffix) {
			return directoryName[:separator], "project"
		}
	}
	return directoryName, "other"
}

func isXcodeDerivedDataHash(value string) bool {
	if len(value) < 20 || len(value) > 40 {
		return false
	}
	for _, character := range value {
		if character < 'a' || character > 'z' {
			return false
		}
	}
	return true
}
