using UnityEngine;

namespace CvUnity.Samples
{
    /// <summary>
    /// Texture2D を OpenCV で処理して書き戻す最小の例。
    ///
    /// 使い方: Renderer を持つ GameObject に付け、Source に RGBA32 の
    /// Texture2D を割り当てる。
    ///
    /// 借用の契約: このサンプルが使う <c>TextureConverter.ToMat</c> /
    /// <c>ToTexture</c> は、テクスチャの生データをコピー無しで渡す。
    /// 呼び出しが戻った時点で借用は終わり、native 側は一切保持しない
    /// （docs/abi-ownership-and-versioning.md §1）。このスクリプト自身は
    /// その呼び出しをまたいでポインタを保持しないので、追加の配慮は要らない。
    /// </summary>
    public sealed class BasicUsage : MonoBehaviour
    {
        [SerializeField] private Texture2D _source;
        [SerializeField] private int _blurKernel = 5;

        private void Start()
        {
            if (_source == null)
            {
                Debug.LogWarning("Source texture is not assigned.");
                return;
            }

            Debug.Log($"OpenCV {CvNative.OpenCvVersion}, ABI {CvNative.AbiVersion}");

            // ToMat はテクスチャの生データを直接読む（コピー 1 回）。
            using var src = CvUnity.Unity.TextureConverter.ToMat(_source);
            using var dst = CvMat.Create(src.Rows, src.Cols, CvMatType.Bgra32);

            CvOps.GaussianBlur(src, dst, _blurKernel, _blurKernel, 0.0, 0.0);

            // 結果を新しいテクスチャへ。元の Texture2D は壊さない。
            var result = new Texture2D(_source.width, _source.height, TextureFormat.RGBA32, false);
            CvUnity.Unity.TextureConverter.ToTexture(dst, result);

            var renderer = GetComponent<Renderer>();
            if (renderer != null && renderer.material != null)
            {
                renderer.material.mainTexture = result;
            }
        }
    }
}
