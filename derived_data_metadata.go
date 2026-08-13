package simslim

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const maximumPackageJSONBytes = 4 * 1024 * 1024

type derivedDataMetadata struct {
	sourcePath        string
	sourceExists      bool
	packageName       string
	packageVersion    string
	packagePath       string
	productName       string
	productPath       string
	bundleIdentifier  string
	marketingVersion  string
	buildNumber       string
	configuration     string
	platform          string
	sdk               string
	minimumOSVersion  string
	productModifiedAt int64
}

type builtAppCandidate struct {
	path          string
	infoPlistPath string
	configuration string
	modifiedAt    int64
}

func inspectDerivedDataMetadata(
	ctx context.Context,
	entryPath string,
	kind string,
) (derivedDataMetadata, error) {
	var metadata derivedDataMetadata
	if kind != "project" {
		return metadata, nil
	}
	if err := ctx.Err(); err != nil {
		return metadata, err
	}

	projectValues := readPlistStringValues(
		ctx,
		filepath.Join(entryPath, "info.plist"),
		[]string{"WorkspacePath", "ProjectPath"},
	)
	metadata.sourcePath = firstNonEmpty(
		projectValues["WorkspacePath"],
		projectValues["ProjectPath"],
	)
	if metadata.sourcePath != "" {
		if _, err := os.Stat(metadata.sourcePath); err == nil {
			metadata.sourceExists = true
		}
		metadata.packageName, metadata.packageVersion, metadata.packagePath =
			findPackageMetadata(metadata.sourcePath)
	}
	if err := ctx.Err(); err != nil {
		return metadata, err
	}

	candidate, ok, err := newestBuiltApp(ctx, filepath.Join(entryPath, "Build", "Products"))
	if err != nil || !ok {
		return metadata, err
	}
	productValues := readPlistStringValues(
		ctx,
		candidate.infoPlistPath,
		[]string{
			"CFBundleDisplayName",
			"CFBundleName",
			"CFBundleIdentifier",
			"CFBundleShortVersionString",
			"CFBundleVersion",
			"DTPlatformName",
			"DTSDKName",
			"MinimumOSVersion",
		},
	)
	if err := ctx.Err(); err != nil {
		return metadata, err
	}

	metadata.productName = firstNonEmpty(
		productValues["CFBundleDisplayName"],
		productValues["CFBundleName"],
		strings.TrimSuffix(filepath.Base(candidate.path), filepath.Ext(candidate.path)),
	)
	metadata.productPath = candidate.path
	metadata.bundleIdentifier = productValues["CFBundleIdentifier"]
	metadata.marketingVersion = productValues["CFBundleShortVersionString"]
	metadata.buildNumber = productValues["CFBundleVersion"]
	metadata.configuration = candidate.configuration
	metadata.platform = productValues["DTPlatformName"]
	metadata.sdk = productValues["DTSDKName"]
	metadata.minimumOSVersion = productValues["MinimumOSVersion"]
	metadata.productModifiedAt = candidate.modifiedAt
	return metadata, nil
}

func applyDerivedDataMetadata(entry *DerivedDataEntry, metadata derivedDataMetadata) {
	entry.SourcePath = metadata.sourcePath
	entry.SourceExists = metadata.sourceExists
	entry.PackageName = metadata.packageName
	entry.PackageVersion = metadata.packageVersion
	entry.PackagePath = metadata.packagePath
	entry.ProductName = metadata.productName
	entry.ProductPath = metadata.productPath
	entry.BundleIdentifier = metadata.bundleIdentifier
	entry.MarketingVersion = metadata.marketingVersion
	entry.BuildNumber = metadata.buildNumber
	entry.Configuration = metadata.configuration
	entry.Platform = metadata.platform
	entry.SDK = metadata.sdk
	entry.MinimumOSVersion = metadata.minimumOSVersion
	entry.ProductModifiedAt = metadata.productModifiedAt
}

func newestBuiltApp(
	ctx context.Context,
	productsRoot string,
) (builtAppCandidate, bool, error) {
	configurations, err := os.ReadDir(productsRoot)
	if os.IsNotExist(err) {
		return builtAppCandidate{}, false, nil
	}
	if err != nil {
		// A partially written or unreadable Products directory should not make
		// the size inventory unusable; metadata is intentionally best effort.
		return builtAppCandidate{}, false, nil
	}

	var newest builtAppCandidate
	found := false
	for _, configurationEntry := range configurations {
		if err := ctx.Err(); err != nil {
			return builtAppCandidate{}, false, err
		}
		if !configurationEntry.IsDir() || configurationEntry.Type()&os.ModeSymlink != 0 {
			continue
		}
		configurationPath := filepath.Join(productsRoot, configurationEntry.Name())
		products, err := os.ReadDir(configurationPath)
		if err != nil {
			continue
		}
		for _, productEntry := range products {
			if err := ctx.Err(); err != nil {
				return builtAppCandidate{}, false, err
			}
			if !productEntry.IsDir() || productEntry.Type()&os.ModeSymlink != 0 ||
				!strings.HasSuffix(strings.ToLower(productEntry.Name()), ".app") ||
				isTestRunnerApp(productEntry.Name()) {
				continue
			}

			productPath := filepath.Join(configurationPath, productEntry.Name())
			productInfo, err := os.Lstat(productPath)
			if err != nil || !productInfo.IsDir() || productInfo.Mode()&os.ModeSymlink != 0 {
				continue
			}
			infoPlistPath := filepath.Join(productPath, "Info.plist")
			plistInfo, err := os.Lstat(infoPlistPath)
			if err != nil || !plistInfo.Mode().IsRegular() || plistInfo.Mode()&os.ModeSymlink != 0 {
				continue
			}

			candidate := builtAppCandidate{
				path:          productPath,
				infoPlistPath: infoPlistPath,
				configuration: buildConfigurationName(configurationEntry.Name()),
				modifiedAt:    productInfo.ModTime().Unix(),
			}
			if !found || candidate.modifiedAt > newest.modifiedAt ||
				(candidate.modifiedAt == newest.modifiedAt && candidate.path < newest.path) {
				newest = candidate
				found = true
			}
		}
	}
	return newest, found, nil
}

func isTestRunnerApp(name string) bool {
	lower := strings.ToLower(name)
	return strings.Contains(lower, "uitests") ||
		strings.Contains(lower, "tests-runner") ||
		strings.HasSuffix(lower, "tests.app")
}

func buildConfigurationName(productsDirectoryName string) string {
	knownPlatforms := []string{
		"iphonesimulator",
		"iphoneos",
		"appletvsimulator",
		"appletvos",
		"watchsimulator",
		"watchos",
		"xrsimulator",
		"xros",
		"maccatalyst",
		"macosx",
	}
	lower := strings.ToLower(productsDirectoryName)
	for _, platform := range knownPlatforms {
		suffix := "-" + platform
		if strings.HasSuffix(lower, suffix) {
			return productsDirectoryName[:len(productsDirectoryName)-len(suffix)]
		}
	}
	return productsDirectoryName
}

func readPlistStringValues(
	ctx context.Context,
	path string,
	keys []string,
) map[string]string {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return map[string]string{}
	}
	wanted := make(map[string]bool, len(keys))
	for _, key := range keys {
		wanted[key] = true
	}
	if values, err := readXMLPlistStringValues(path, wanted); err == nil {
		return values
	}

	// Built product plists may be binary. plutil is present on every supported
	// host Mac and lets us read just the allowlisted scalar keys.
	values := make(map[string]string)
	for _, key := range keys {
		if ctx.Err() != nil {
			return values
		}
		output, err := exec.CommandContext(
			ctx,
			"/usr/bin/plutil",
			"-extract",
			key,
			"raw",
			"-o",
			"-",
			path,
		).Output()
		if err != nil {
			continue
		}
		if value := strings.TrimSpace(string(output)); value != "" {
			values[key] = value
		}
	}
	return values
}

func readXMLPlistStringValues(
	path string,
	wanted map[string]bool,
) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	decoder := xml.NewDecoder(file)
	values := make(map[string]string)
	collectionDepth := 0
	pendingKey := ""
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return values, nil
		}
		if err != nil {
			return nil, err
		}

		switch typed := token.(type) {
		case xml.StartElement:
			switch typed.Name.Local {
			case "dict", "array":
				if collectionDepth == 1 {
					pendingKey = ""
				}
				collectionDepth++
			case "key":
				if collectionDepth != 1 {
					continue
				}
				var key string
				if err := decoder.DecodeElement(&key, &typed); err != nil {
					return nil, err
				}
				pendingKey = key
			case "string", "integer", "real", "date":
				if collectionDepth != 1 || pendingKey == "" {
					continue
				}
				var value string
				if err := decoder.DecodeElement(&value, &typed); err != nil {
					return nil, err
				}
				if wanted[pendingKey] {
					values[pendingKey] = strings.TrimSpace(value)
				}
				pendingKey = ""
			case "true", "false":
				if collectionDepth == 1 && wanted[pendingKey] {
					values[pendingKey] = typed.Name.Local
				}
				pendingKey = ""
			}
		case xml.EndElement:
			if typed.Name.Local == "dict" || typed.Name.Local == "array" {
				collectionDepth--
			}
		}
	}
}

func findPackageMetadata(sourcePath string) (name, version, path string) {
	if sourcePath == "" {
		return "", "", ""
	}
	directory := sourcePath
	if strings.HasSuffix(sourcePath, ".xcworkspace") ||
		strings.HasSuffix(sourcePath, ".xcodeproj") ||
		filepath.Ext(sourcePath) != "" {
		directory = filepath.Dir(sourcePath)
	} else if info, err := os.Stat(sourcePath); err == nil && !info.IsDir() {
		directory = filepath.Dir(sourcePath)
	}
	directory = filepath.Clean(directory)
	home, _ := os.UserHomeDir()

	for range 6 {
		packagePath := filepath.Join(directory, "package.json")
		if packageName, packageVersion, ok := readPackageMetadata(packagePath); ok {
			return packageName, packageVersion, packagePath
		}
		if directory == home {
			break
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			break
		}
		directory = parent
	}
	return "", "", ""
}

func readPackageMetadata(path string) (name, version string, ok bool) {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximumPackageJSONBytes {
		return "", "", false
	}
	file, err := os.Open(path)
	if err != nil {
		return "", "", false
	}
	defer file.Close()

	var manifest struct {
		Name    string          `json:"name"`
		Version json.RawMessage `json:"version"`
	}
	decoder := json.NewDecoder(io.LimitReader(file, maximumPackageJSONBytes+1))
	if err := decoder.Decode(&manifest); err != nil {
		return "", "", false
	}
	version = jsonScalarString(manifest.Version)
	if manifest.Name == "" && version == "" {
		return "", "", false
	}
	return manifest.Name, version, true
}

func jsonScalarString(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return text
	}
	var number json.Number
	if err := json.Unmarshal(raw, &number); err == nil {
		return number.String()
	}
	var boolean bool
	if err := json.Unmarshal(raw, &boolean); err == nil {
		return strconv.FormatBool(boolean)
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

// FormatDerivedDataMetadata returns the compact metadata summary used by the
// human-readable CLI output.
func FormatDerivedDataMetadata(entry DerivedDataEntry) string {
	parts := make([]string, 0, 6)
	if entry.BundleIdentifier != "" {
		parts = append(parts, entry.BundleIdentifier)
	}
	if entry.MarketingVersion != "" {
		parts = append(parts, "app "+entry.MarketingVersion)
	}
	if entry.BuildNumber != "" {
		parts = append(parts, "build "+entry.BuildNumber)
	}
	if entry.PackageVersion != "" {
		parts = append(parts, "package "+entry.PackageVersion)
	}
	if entry.Configuration != "" {
		parts = append(parts, entry.Configuration)
	}
	if entry.Platform != "" {
		parts = append(parts, entry.Platform)
	}
	return strings.Join(parts, " · ")
}
