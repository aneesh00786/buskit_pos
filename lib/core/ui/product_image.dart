import 'package:flutter/material.dart';

import '../../features/products/models/product_item.dart';
import '../theme/pos_tokens.dart';

/// Product image with a neutral placeholder for missing, loading or broken
/// images. Automatically resolves relative paths against the server and
/// provides staging/production domain fallback.
class ProductImage extends StatefulWidget {
  const ProductImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
  });

  final String? url;
  final BoxFit fit;

  @override
  State<ProductImage> createState() => _ProductImageState();
}

class _ProductImageState extends State<ProductImage> {
  bool _triedFallback = false;

  @override
  void didUpdateWidget(ProductImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _triedFallback = false;
    }
  }

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

    final raw = widget.url;
    if (raw == null || raw.trim().isEmpty) return placeholder;

    final resolved = ProductItem.cleanUrl(raw);
    if (resolved == null) return placeholder;

    String effectiveUrl = resolved;
    if (_triedFallback) {
      if (resolved.contains('test.thrivewoo.com')) {
        effectiveUrl = resolved.replaceFirst(
          'test.thrivewoo.com',
          'thrivewoo.com',
        );
      } else if (resolved.contains('thrivewoo.com')) {
        effectiveUrl = resolved.replaceFirst(
          'thrivewoo.com',
          'test.thrivewoo.com',
        );
      }
    }

    final canFallback = !_triedFallback &&
        (resolved.contains('test.thrivewoo.com') ||
            resolved.contains('thrivewoo.com'));

    return Image.network(
      effectiveUrl,
      fit: widget.fit,
      excludeFromSemantics: true,
      errorBuilder: (context, error, stackTrace) {
        if (canFallback) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _triedFallback = true;
              });
            }
          });
          return placeholder;
        }
        return placeholder;
      },
      loadingBuilder: (c, child, p) => p == null ? child : placeholder,
    );
  }
}
