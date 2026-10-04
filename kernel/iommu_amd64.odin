package kernel

import vx "abi:vx"

// The IOMMU: none driven yet, so every DMA domain is pass-through
// (device.odin).

iommu_init :: proc "contextless" () {}

@(require_results)
iommu_attach :: proc "contextless" (d: ^Dma_Domain) -> vx.Status {
	return .Ok // no IOMMU in front of it: pass-through
}

iommu_detach :: proc "contextless" (d: ^Dma_Domain) {}

@(require_results)
iommu_map :: proc "contextless" (d: ^Dma_Domain, iova: u64, pages: []Page, options: vx.Dma_Options) -> bool {
	return false
}

iommu_unmap :: proc "contextless" (d: ^Dma_Domain, iova, count: u64) {}
