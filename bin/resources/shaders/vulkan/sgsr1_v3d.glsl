#version 460 core
#extension GL_EXT_samplerless_texture_functions : require

// Copyright (c) 2025, Qualcomm Innovation Center, Inc. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
//
// Compute adaptation of the SGSR1 mobile shader for ARMSX2's existing Vulkan
// CAS resource path. The push constants are the CasSetup values already emitted
// by GSDevice::CAS; const0.xy encode source-to-output scale and srcOffset selects
// the active GS presentation rectangle.

layout(push_constant) uniform const_buffer
{
	uvec4 const0;
	uvec4 const1;
	ivec2 srcOffset;
};

layout(set = 0, binding = 0) uniform texture2D imgSrc;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D imgDst;
layout(set = 0, binding = 2) uniform sampler linearSampler;

layout(local_size_x = 8, local_size_y = 8) in;

const float EDGE_THRESHOLD = 8.0 / 255.0;
const float EDGE_SHARPNESS = 2.0;

float FastLanczos2(float x)
{
	float wa = x - 4.0;
	float wb = x * wa - wa;
	wa *= wa;
	return wb * wa;
}

vec2 WeightY(float dx, float dy, float contrast, float stddev)
{
	float x = (dx * dx + dy * dy) * 0.55 + clamp(abs(contrast) * stddev, 0.0, 1.0);
	float weight = FastLanczos2(x);
	return vec2(weight, weight * contrast);
}

void main()
{
	ivec2 output_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 output_size = imageSize(imgDst);
	if (any(greaterThanEqual(output_pixel, output_size)))
		return;

	vec2 scale = uintBitsToFloat(const0.xy);
	vec2 source_size = vec2(textureSize(imgSrc, 0));
	vec2 output_center = vec2(output_pixel) + vec2(0.5);
	vec2 source_position = output_center * scale;
	vec2 uv = (vec2(srcOffset) + source_position) / source_size;
	vec3 color = textureLod(sampler2D(imgSrc, linearSampler), uv, 0.0).rgb;

	vec2 image_coord = source_position + vec2(-0.5, 0.5);
	vec2 image_pixel = floor(image_coord);
	vec2 phase = image_coord - image_pixel;
	vec2 coord = (vec2(srcOffset) + image_pixel) / source_size;

	vec4 left = textureGather(sampler2D(imgSrc, linearSampler), coord, 1);
	float edge_vote =
		abs(left.z - left.y) + abs(color.g - left.y) + abs(color.g - left.z);
	if (edge_vote > EDGE_THRESHOLD)
	{
		coord.x += 1.0 / source_size.x;
		vec4 right = textureGather(
			sampler2D(imgSrc, linearSampler), coord + vec2(1.0 / source_size.x, 0.0), 1);
		vec4 up_down;
		up_down.xy = textureGather(
			sampler2D(imgSrc, linearSampler), coord + vec2(0.0, -1.0 / source_size.y), 1).wz;
		up_down.zw = textureGather(
			sampler2D(imgSrc, linearSampler), coord + vec2(0.0, 1.0 / source_size.y), 1).yx;

		float mean = (left.y + left.z + right.x + right.w) * 0.25;
		left -= vec4(mean);
		right -= vec4(mean);
		up_down -= vec4(mean);
		float center = color.g - mean;
		float sum = dot(abs(left), vec4(1.0)) + dot(abs(right), vec4(1.0)) +
		            dot(abs(up_down), vec4(1.0));
		float stddev = 2.181818 / max(sum, 1.0e-6);

		vec2 weights = WeightY(phase.x, phase.y + 1.0, up_down.x, stddev);
		weights += WeightY(phase.x - 1.0, phase.y + 1.0, up_down.y, stddev);
		weights += WeightY(phase.x - 1.0, phase.y - 2.0, up_down.z, stddev);
		weights += WeightY(phase.x, phase.y - 2.0, up_down.w, stddev);
		weights += WeightY(phase.x + 1.0, phase.y - 1.0, left.x, stddev);
		weights += WeightY(phase.x, phase.y - 1.0, left.y, stddev);
		weights += WeightY(phase.x, phase.y, left.z, stddev);
		weights += WeightY(phase.x + 1.0, phase.y, left.w, stddev);
		weights += WeightY(phase.x - 1.0, phase.y - 1.0, right.x, stddev);
		weights += WeightY(phase.x - 2.0, phase.y - 1.0, right.y, stddev);
		weights += WeightY(phase.x - 2.0, phase.y, right.z, stddev);
		weights += WeightY(phase.x - 1.0, phase.y, right.w, stddev);

		float filtered = weights.y / max(weights.x, 1.0e-6);
		float max_y = max(max(left.y, left.z), max(right.x, right.w));
		float min_y = min(min(left.y, left.z), min(right.x, right.w));
		float delta = clamp(EDGE_SHARPNESS * filtered, min_y, max_y) - center;
		delta = clamp(delta, -23.0 / 255.0, 23.0 / 255.0);
		color = clamp(color + vec3(delta), 0.0, 1.0);
	}

	imageStore(imgDst, output_pixel, vec4(color, 1.0));
}
