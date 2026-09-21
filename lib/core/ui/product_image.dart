import 'package:flutter/material.dart';

import '../theme/pos_tokens.dart';

/// Product image with a neutral placeholder for missing, loading or broken
/// images.
class ProductImage extends StatelessWidget {
  const ProductImage({super.key, required this.url, this.fit = BoxFit.cover});
  final String? url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final placeholder = ColoredBox(
      color: t.surfaceMuted,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
    if (url == null) return placeholder;
    return Image.network(
      url!,
      fit: fit,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => placeholder,
      loadingBuilder: (c, child, p) => p == null ? child : placeholder,
    );
  }
}
