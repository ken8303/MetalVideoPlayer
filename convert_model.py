"""
One-time conversion of Real-ESRGAN (realesr-animevideov3) to Core ML.

Run via `bash convert-model.sh` — it sets up the Python environment,
downloads the weights, runs this script, and installs the resulting
RealESRGAN.mlpackage into ~/Library/Application Support/SuperResVideoPlayer/.

The network is SRVGGNetCompact (the compact video-oriented Real-ESRGAN
variant): tiny (~2.4 MB), fast, trained for anime video. Defined inline so
no basicsr/realesrgan package dependency is needed. License: BSD-3-Clause
(Real-ESRGAN, Xintao Wang et al.).

Input:  512x512 RGB image, values scaled 1/255 into the model.
Output: 2048x2048 RGB image (4x), clamped back to 0-255.
The app runs it on overlapping tiles and resamples back to native size.
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

WEIGHTS = "realesr-animevideov3.pth"
TILE = 512
SCALE = 4


class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        base = F.interpolate(x, scale_factor=self.upscale, mode="nearest")
        return out + base


class ImageWrapped(nn.Module):
    """Maps the model's 0..1 float output to the 0..255 range Core ML
    image outputs expect."""

    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, x):
        return torch.clamp(self.inner(x) * 255.0, 0.0, 255.0)


def main():
    net = SRVGGNetCompact(upscale=SCALE)
    state = torch.load(WEIGHTS, map_location="cpu", weights_only=True)
    if "params" in state:
        state = state["params"]
    net.load_state_dict(state, strict=True)
    net.eval()

    wrapped = ImageWrapped(net).eval()
    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(wrapped, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, TILE, TILE),
                             scale=1.0 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="enhanced", color_layout=ct.colorlayout.RGB)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "Real-ESRGAN (realesr-animevideov3) 4x, 512px tiles"
    mlmodel.save("RealESRGAN.mlpackage")
    print("Saved RealESRGAN.mlpackage")


if __name__ == "__main__":
    main()
